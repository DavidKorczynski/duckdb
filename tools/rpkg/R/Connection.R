#' DuckDB driver class
#'
#' Implements \linkS4class{DBIDriver}.
#'
#' @aliases duckdb_driver
#' @keywords internal
#' @export
setClass("duckdb_driver", contains = "DBIDriver", slots = list(database_ref = "externalptr", dbdir = "character", read_only = "logical"))

#' DuckDB connection class
#'
#' Implements \linkS4class{DBIConnection}.
#'
#' @aliases duckdb_connection
#' @keywords internal
#' @export
setClass("duckdb_connection",
  contains = "DBIConnection",
  slots = list(conn_ref = "externalptr",
               driver = "duckdb_driver",
               debug = "logical",
               timezone_out = "character",
               tz_out_convert = "character")
)

duckdb_connection <- function(duckdb_driver, debug) {
  new(
    "duckdb_connection",
    conn_ref = .Call(duckdb_connect_R, duckdb_driver@database_ref),
    driver = duckdb_driver,
    debug = debug,
    timezone_out = "UTC",
    tz_out_convert = "with"
  )
}

#' @rdname duckdb_connection-class
#' @inheritParams methods::show
#' @export
setMethod(
  "show", "duckdb_connection",
  function(object) {
    message(sprintf("<duckdb_connection %s driver=%s>", extptr_str(object@conn_ref), drv_to_string(object@driver)))
    invisible(NULL)
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbIsValid
#' @export
setMethod(
  "dbIsValid", "duckdb_connection",
  function(dbObj, ...) {
    valid <- FALSE
    tryCatch(
      {
        dbGetQuery(dbObj, SQL("SELECT 1"))
        valid <- TRUE
      },
      error = function(c) {
      }
    )
    valid
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbSendQuery
#' @inheritParams DBI::dbBind
#' @param arrow Whether the query should be returned as an Arrow Table
#' @export
setMethod(
  "dbSendQuery", c("duckdb_connection", "character"),
  function(conn, statement, params = NULL, ..., arrow=FALSE) {
    if (conn@debug) {
      message("Q ", statement)
    }
    statement <- enc2utf8(statement)
    stmt_lst <- .Call(duckdb_prepare_R, conn@conn_ref, statement)

    res <- duckdb_result(
      connection = conn,
      stmt_lst = stmt_lst,
      arrow = arrow
    )
    if (length(params) > 0) {
      dbBind(res, params)
    }
    return(res)
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbDataType
#' @export
setMethod(
  "dbDataType", "duckdb_connection",
  function(dbObj, obj, ...) {
    dbDataType(dbObj@driver, obj, ...)
  }
)

duckdb_random_string <- function(x) {
  paste(sample(letters, 10, replace = TRUE), collapse = "")
}

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbWriteTable
#' @param row.names Whether the row.names of the data.frame should be preserved
#' @param overwrite If a table with the given name already exists, should it be overwritten?
#' @param append If a table with the given name already exists, just try to append the passed data to it
#' @param field.types Override the auto-generated SQL types
#' @param temporary Should the created table be temporary?
#' @export
setMethod(
  "dbWriteTable", c("duckdb_connection", "character", "data.frame"),
  function(conn,
           name,
           value,
           row.names = FALSE,
           overwrite = FALSE,
           append = FALSE,
           field.types = NULL,
           temporary = FALSE,
           ...) {
    check_flag(overwrite)
    check_flag(append)
    check_flag(temporary)

    # TODO: start a transaction if one is not already running

    if (overwrite && append) {
      stop("Setting both overwrite and append makes no sense")
    }

    if (!is.null(field.types)) {
      if (!(is.character(field.types) && !is.null(names(field.types)) && !anyDuplicated(names(field.types)))) {
        stop("`field.types` must be a named character vector with unique names, or NULL")
      }
    }
    if (append && !is.null(field.types)) {
      stop("Cannot specify `field.types` with `append = TRUE`")
    }

    value <- as.data.frame(value)
    if (!is.data.frame(value)) {
      stop("need a data frame as parameter")
    }

    # use Kirill's magic, convert rownames to additional column
    value <- sqlRownamesToColumn(value, row.names)

    if (dbExistsTable(conn, name)) {
      if (overwrite) {
        dbRemoveTable(conn, name)
      }
      if (!overwrite && !append) {
        stop(
          "Table ",
          name,
          " already exists. Set `overwrite = TRUE` if you want to remove the existing table. ",
          "Set `append = TRUE` if you would like to add the new data to the existing table."
        )
      }
    }
    table_name <- dbQuoteIdentifier(conn, name)

    if (!dbExistsTable(conn, name)) {
        view_name <- sprintf("_duckdb_write_view_%s", duckdb_random_string())
        on.exit(duckdb_unregister(conn, view_name))
        duckdb_register(conn, view_name, value)

        temp_str <- ""
        if (temporary) temp_str <- "TEMPORARY"

        col_names <- dbGetQuery(conn, SQL(sprintf(
          "DESCRIBE %s", view_name
        )))$Field

        cols <- character()
        col_idx <- 1
        for (name in col_names) {
            if (name %in% names(field.types)) {
                cols <- c(cols, sprintf("#%d::%s %s", col_idx, field.types[name], name))
            }
            else {
                cols <- c(cols, sprintf("#%d", col_idx))
            }
            col_idx <- col_idx + 1
         }
        dbExecute(conn, SQL(sprintf("CREATE %s TABLE %s AS SELECT %s FROM %s", temp_str, table_name, paste(cols, collapse=","), view_name)))
        rs_on_connection_updated(conn, hint=paste0("Create table'", table_name,"'"))
    } else {
        dbAppendTable(conn, name, value)
    }
    invisible(TRUE)
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbAppendTable
#' @export
setMethod(
  "dbAppendTable", "duckdb_connection",
  function(conn, name, value, ..., row.names = NULL) {
    if (!is.null(row.names)) {
      stop("Can't pass `row.names` to `dbAppendTable()`")
    }

    target_names <- dbListFields(conn, name)

    if (!all(names(value) %in% target_names)) {
      stop("Column `", setdiff(names(value), target_names)[[1]], "` does not exist in target table.")
    }

    value <- encode_values(value)

    if (nrow(value)) {
      table_name <- dbQuoteIdentifier(conn, name)

      view_name <- sprintf("_duckdb_append_view_%s", duckdb_random_string())
      on.exit(duckdb_unregister(conn, view_name))
      duckdb_register(conn, view_name, value)

      sql <- paste0(
        "INSERT INTO ", table_name, "\n",
        "(", paste(dbQuoteIdentifier(conn, names(value)), collapse = ", "), ")\n",
        "SELECT * FROM ", view_name
      )

      dbExecute(conn, sql)

      rs_on_connection_updated(conn, hint=paste0("Updated table'", table_name,"'"))
    }

    invisible(nrow(value))
  }
)

encode_values <- function(value) {
  is_factor <- vapply(value, is.factor, logical(1))
  if (any(is_factor)) {
    warning("Factors converted to character")
  }

  value[is_factor] <- lapply(value[is_factor], function(x) {
    levels(x) <- enc2utf8(levels(x))
    as.character(x)
  })

  is_character <- vapply(value, is.character, logical(1))
  value[is_character] <- lapply(value[is_character], enc2utf8)

  is_posixlt <- vapply(value, inherits, "POSIXlt", FUN.VALUE = logical(1))
  value[is_posixlt] <- lapply(value[is_posixlt], as.POSIXct)

  value
}

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbListTables
#' @export
setMethod(
  "dbListTables", "duckdb_connection",
  function(conn, ...) {
    dbGetQuery(
      conn,
      SQL(
        "SELECT name FROM sqlite_master WHERE type='table' OR type='view' ORDER BY name"
      )
    )[[1]]
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbExistsTable
#' @export
setMethod(
  "dbExistsTable", c("duckdb_connection", "character"),
  function(conn, name, ...) {
    if (!dbIsValid(conn)) {
      stop("Invalid connection")
    }
    if (length(name) != 1) {
      stop("Can only have a single name argument")
    }
    exists <- FALSE
    tryCatch(
      {
        dbGetQuery(
          conn,
          sqlInterpolate(
            conn,
            "SELECT * FROM ? WHERE FALSE",
            dbQuoteIdentifier(conn, name)
          )
        )
        exists <- TRUE
      },
      error = function(c) {
      }
    )
    exists
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbListFields
#' @export
setMethod(
  "dbListFields", c("duckdb_connection", "character"),
  function(conn, name, ...) {
    names(dbGetQuery(
      conn,
      sqlInterpolate(
        conn,
        "SELECT * FROM ? WHERE FALSE",
        dbQuoteIdentifier(conn, name)
      )
    ))
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbRemoveTable
#' @export
setMethod(
  "dbRemoveTable", c("duckdb_connection", "character"),
  function(conn, name, ..., fail_if_missing = TRUE) {
    sql <- paste0("DROP TABLE ", if (!fail_if_missing) "IF EXISTS ", "?")
    dbExecute(
      conn,
      sqlInterpolate(conn, sql, dbQuoteIdentifier(conn, name))
    )
    rs_on_connection_updated(conn, "Table removed")
    invisible(TRUE)
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbGetInfo
#' @export
setMethod(
  "dbGetInfo", "duckdb_connection",
  function(dbObj, ...) {
    info <- dbGetInfo(dbObj@driver)
    list(
      dbname = info$dbname,
      db.version = info$driver.version,
      username = NA,
      host = NA,
      port = NA
    )
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbBegin
#' @export
setMethod(
  "dbBegin", "duckdb_connection",
  function(conn, ...) {
    dbExecute(conn, SQL("BEGIN TRANSACTION"))
    invisible(TRUE)
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbCommit
#' @export
setMethod(
  "dbCommit", "duckdb_connection",
  function(conn, ...) {
    dbExecute(conn, SQL("COMMIT"))
    invisible(TRUE)
  }
)

#' @rdname duckdb_connection-class
#' @inheritParams DBI::dbRollback
#' @export
setMethod(
  "dbRollback", "duckdb_connection",
  function(conn, ...) {
    dbExecute(conn, SQL("ROLLBACK"))
    invisible(TRUE)
  }
)

#' @rdname duckdb_connection-class
#' @export
setMethod(
  "dbQuoteLiteral", signature("duckdb_connection"),
  function(conn, x, ...) {
    # Switchpatching to avoid ambiguous S4 dispatch, so that our method
    # is used only if no alternatives are available.

    if (is(x, "SQL")) {
      return(x)
    }

    if (is.factor(x)) {
      return(dbQuoteString(conn, as.character(x)))
    }

    if (is.character(x)) {
      return(dbQuoteString(conn, x))
    }

    if (inherits(x, "POSIXt")) {
      out <- dbQuoteString(
        conn,
        strftime(as.POSIXct(x), "%Y-%m-%d %H:%M:%S", tz = "UTC")
      )

      return(SQL(paste0(out, "::timestamp")))
    }

    if (inherits(x, "Date")) {
      out <- callNextMethod()
      return(SQL(paste0(out, "::date")))
    }

    if (inherits(x, "difftime")) {
      out <- callNextMethod()
      return(SQL(paste0(out, "::time")))
    }

    if (is.list(x)) {
      blob_data <- vapply(
        x,
        function(x) {
          if (is.null(x)) {
            "NULL"
          } else if (is.raw(x)) {
            paste0("X'", paste(format(x), collapse = ""), "'")
          } else {
            stop("Lists must contain raw vectors or NULL", call. = FALSE)
          }
        },
        character(1)
      )
      return(SQL(blob_data, names = names(x)))
    }

    x <- as.character(x)
    x[is.na(x)] <- "NULL"
    SQL(x, names = names(x))
  }
)
