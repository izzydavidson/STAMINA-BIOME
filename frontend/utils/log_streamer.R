# Log Streaming Utilities
# Functions to stream and parse pipeline logs in real-time

parse_ansi_colors <- function(log_line) {
  # Parse ANSI color codes and convert to HTML classes
  # This preserves the color coding from CLI logs

  # ANSI color codes to HTML class mappings
  color_map <- list(
    "\\033\\[31m" = "log-error",      # Red
    "\\033\\[33m" = "log-warning",    # Yellow
    "\\033\\[32m" = "log-success",    # Green
    "\\033\\[36m" = "log-info",       # Cyan
    "\\033\\[35m" = "log-info",       # Purple
    "\\033\\[0m" = "",                # Reset
    "\\033\\[1m" = "",                # Bold (ignore)
    "\\033\\[2m" = ""                 # Dim (ignore)
  )

  # Remove ANSI codes but detect what color was used
  class_name <- ""

  for (code in names(color_map)) {
    if (grepl(code, log_line)) {
      class_name <- color_map[[code]]
      break
    }
  }

  # Remove all ANSI codes
  cleaned_line <- gsub("\\033\\[[0-9;]+m", "", log_line)

  list(
    text = cleaned_line,
    class = class_name
  )
}

format_log_line <- function(log_line, auto_color = TRUE) {
  # Format a log line with appropriate HTML styling

  parsed <- parse_ansi_colors(log_line)

  # Auto-detect error/warning/success if not already colored
  if (auto_color && parsed$class == "") {
    if (grepl("ERROR|FAIL|FAILED", log_line, ignore.case = TRUE)) {
      parsed$class <- "log-error"
    } else if (grepl("WARN|WARNING", log_line, ignore.case = TRUE)) {
      parsed$class <- "log-warning"
    } else if (grepl("SUCCESS|COMPLETED|DONE|OK", log_line, ignore.case = TRUE)) {
      parsed$class <- "log-success"
    } else if (grepl("INFO|STEP|STAGE|\\[.*\\]", log_line, ignore.case = TRUE)) {
      parsed$class <- "log-info"
    }
  }

  tags$div(class = parsed$class, parsed$text)
}

stream_process_output <- function(process_handle, callback) {
  # Stream output from a running process
  # callback: function to call with each new line

  while (TRUE) {
    # Check if process is still running
    status <- tryCatch({
      sys::exec_status(process_handle, wait = FALSE)
    }, error = function(e) list(status = -1))

    # Read stdout
    if (!is.null(status$stdout) && length(status$stdout) > 0) {
      lines <- strsplit(rawToChar(status$stdout), "\n")[[1]]
      for (line in lines) {
        if (nchar(line) > 0) {
          callback(line)
        }
      }
    }

    # Read stderr
    if (!is.null(status$stderr) && length(status$stderr) > 0) {
      lines <- strsplit(rawToChar(status$stderr), "\n")[[1]]
      for (line in lines) {
        if (nchar(line) > 0) {
          callback(paste("[STDERR]", line))
        }
      }
    }

    # Exit if process finished
    if (!is.null(status$status)) {
      break
    }

    # Sleep briefly
    Sys.sleep(0.1)
  }

  status$status
}

watch_log_file <- function(log_file_path, callback, interval = 0.5) {
  # Watch a log file for new content and stream it
  # callback: function to call with each new line

  if (!file.exists(log_file_path)) {
    return(NULL)
  }

  last_position <- 0

  while (TRUE) {
    # Check if file still exists
    if (!file.exists(log_file_path)) {
      break
    }

    # Get current file size
    file_size <- file.info(log_file_path)$size

    if (file_size > last_position) {
      # Read new content
      con <- file(log_file_path, "r")
      seek(con, last_position)
      new_lines <- readLines(con)
      close(con)

      # Process new lines
      for (line in new_lines) {
        callback(line)
      }

      last_position <- file_size
    }

    # Sleep briefly
    Sys.sleep(interval)
  }
}

tail_log_file <- function(log_file_path, n = 100) {
  # Get the last n lines from a log file
  if (!file.exists(log_file_path)) {
    return(character(0))
  }

  all_lines <- readLines(log_file_path, warn = FALSE)
  tail(all_lines, n)
}

get_run_logs <- function(run_id) {
  # Get all logs for a specific run
  outputs_dir <- get_outputs_directory()
  logs_dir <- file.path(outputs_dir, run_id, "logs")

  if (!dir.exists(logs_dir)) {
    return(list())
  }

  log_files <- list.files(logs_dir, pattern = "\\.log$", full.names = TRUE)

  logs <- lapply(log_files, function(log_file) {
    list(
      name = basename(log_file),
      content = readLines(log_file, warn = FALSE)
    )
  })

  setNames(logs, sapply(logs, function(x) x$name))
}
