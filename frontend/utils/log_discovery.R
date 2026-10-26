# Log Discovery and Safe Reading Utilities
# Handles distributed log structure across dispatcher and step-specific logs

discover_run_logs <- function(run_dir, pipeline_key) {
  # Discovers all log files for a pipeline run
  # Returns structured list of log sources

  if (!dir.exists(run_dir)) {
    return(list())
  }

  logs <- list()

  # 0. Wrapper log — captured stdout/stderr of run_with_postprocess.sh.
  #    Pre-created before the process starts so it exists even on fast failures
  #    (e.g. exit code 125 before any pipeline log files are written).
  wrapper_log <- file.path(run_dir, "logs", "wrapper.log")
  if (file.exists(wrapper_log)) {
    logs[[length(logs) + 1]] <- list(
      name = "wrapper",
      display_name = "Pipeline (wrapper)",
      path = wrapper_log,
      type = "wrapper",
      order = -1
    )
  }

  # 1. Dispatcher log (always first)
  dispatcher_log <- file.path(run_dir, "logs", paste0(pipeline_key, ".log"))
  if (file.exists(dispatcher_log)) {
    logs[[length(logs) + 1]] <- list(
      name = "Dispatcher",
      display_name = "Pipeline Dispatcher",
      path = dispatcher_log,
      type = "dispatcher",
      order = 0
    )
  }

  # 2. Step-specific logs (search root + one subdirectory level)
  step_logs_dir <- file.path(run_dir, pipeline_key, "logs")
  if (dir.exists(step_logs_dir)) {
    # Recursive = TRUE captures both root logs and r_postprocess/ subdirectory
    step_log_files <- list.files(step_logs_dir, pattern = "\\.log$",
                                  full.names = TRUE, recursive = TRUE)

    if (length(step_log_files) > 0) {
      # Sort alphabetically (z_frontend_postprocess.log sorts last)
      step_log_files <- sort(step_log_files)

      for (i in seq_along(step_log_files)) {
        log_file <- step_log_files[i]
        log_basename <- basename(log_file)

        # Create display name from filename
        display_name <- gsub("\\.log$", "", log_basename)
        display_name <- tools::toTitleCase(display_name)

        # Prefix subdirectory name to display name for clarity
        rel_dir <- dirname(log_file)
        sub_name <- basename(rel_dir)
        if (sub_name != "logs") {
          display_name <- paste0(tools::toTitleCase(sub_name), " / ", display_name)
        }

        logs[[length(logs) + 1]] <- list(
          name = log_basename,
          display_name = display_name,
          path = log_file,
          type = "step",
          order = i
        )
      }
    }
  }

  logs
}

safe_read_log_file <- function(log_path, max_lines = 10000, tail_mode = FALSE) {
  # Safely reads a log file with path traversal protection
  # Returns list with content and metadata

  # Path traversal protection
  if (grepl("\\.\\.", log_path, fixed = TRUE)) {
    return(list(
      success = FALSE,
      error = "Path traversal detected",
      content = character(0)
    ))
  }

  # Normalize path
  log_path_norm <- normalizePath(log_path, mustWork = FALSE)

  # Check file exists
  if (!file.exists(log_path_norm)) {
    return(list(
      success = FALSE,
      error = "Log file not found",
      content = character(0)
    ))
  }

  # Check file size
  file_size <- file.info(log_path_norm)$size
  if (is.na(file_size)) {
    return(list(
      success = FALSE,
      error = "Cannot read file info",
      content = character(0)
    ))
  }

  # Read content
  content <- tryCatch({
    if (tail_mode && file_size > 1000000) {
      # For large files in tail mode, use system tail
      system(paste("tail -n", max_lines, shQuote(log_path_norm)), intern = TRUE)
    } else {
      # Read entire file
      all_lines <- readLines(log_path_norm, warn = FALSE)

      # If too many lines, take last N
      if (length(all_lines) > max_lines) {
        tail(all_lines, max_lines)
      } else {
        all_lines
      }
    }
  }, error = function(e) {
    return(character(0))
  })

  list(
    success = TRUE,
    content = content,
    total_lines = length(content),
    file_size = file_size,
    truncated = length(content) >= max_lines
  )
}

stream_log_file <- function(log_path, callback, last_position = 0) {
  # Streams new content from a log file
  # Returns new position

  if (!file.exists(log_path)) {
    return(last_position)
  }

  current_size <- file.info(log_path)$size

  if (is.na(current_size) || current_size <= last_position) {
    return(last_position)
  }

  # Read new content
  tryCatch({
    con <- file(log_path, "r")
    seek(con, last_position)
    new_lines <- readLines(con, warn = FALSE)
    close(con)

    # Call callback for each new line
    if (length(new_lines) > 0) {
      for (line in new_lines) {
        callback(line)
      }
    }

    current_size
  }, error = function(e) {
    last_position
  })
}

get_log_tail_live <- function(log_path, n = 50) {
  # Get last N lines efficiently for live monitoring

  if (!file.exists(log_path)) {
    return(character(0))
  }

  result <- safe_read_log_file(log_path, max_lines = n, tail_mode = TRUE)

  if (result$success) {
    result$content
  } else {
    character(0)
  }
}
