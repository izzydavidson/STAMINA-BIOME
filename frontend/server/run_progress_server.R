run_progress_server <- function(id, shared) {
  moduleServer(id, function(input, output, session) {

    # Process handle for the running pipeline
    process <- reactiveVal(NULL)
    log_buffer <- reactiveVal(character(0))
    process_timer <- reactiveVal(NULL)
    stdout_position <- reactiveVal(0)
    stderr_position <- reactiveVal(0)

    # Display run information
    output$run_id <- renderText({
      if (is.null(shared$current_run)) {
        "No active run"
      } else {
        shared$current_run$run_id
      }
    })

    output$pipeline_name <- renderText({
      if (is.null(shared$current_run)) {
        "—"
      } else {
        switch(shared$current_run$pipeline,
          "sr_amp" = "Short Read 16S Amplicon",
          "sr_meta" = "Short Read Metagenomics",
          "lr_amp" = "Long Read 16S Amplicon",
          "lr_meta" = "Long Read Metagenomics",
          shared$current_run$pipeline
        )
      }
    })

    output$run_status_badge <- renderUI({
      status <- shared$run_status

      badge_class <- switch(status,
        "running" = "bg-primary",
        "completed" = "bg-success",
        "failed" = "bg-danger",
        "stopped" = "bg-warning",
        "bg-secondary"
      )

      tags$span(
        class = paste("badge", badge_class),
        style = "font-size: 1rem; padding: 0.5rem 1rem;",
        toupper(status)
      )
    })

    output$start_time <- renderText({
      if (is.null(shared$current_run)) {
        "—"
      } else {
        format(Sys.time(), "%Y-%m-%d %H:%M:%S")
      }
    })

    output$command_display <- renderText({
      if (is.null(shared$current_run)) {
        "No command to display"
      } else {
        repo_root <- dirname(getwd())
        run_script <- file.path(repo_root, "main", "pipelines", "stamina_biome_run.sh")
        config_file <- shared$current_run$config_file %||% "config.json"

        paste(run_script, "--config", config_file)
      }
    })

    # Execute pipeline when current_run changes or status becomes ready
    observeEvent(shared$run_status, {
      if (!is.null(shared$current_run) && shared$run_status == "ready") {
        execute_pipeline()
      }
    })

    # Execute pipeline
    execute_pipeline <- function() {
      if (is.null(shared$current_run)) {
        return()
      }

      log_buffer(character(0))
      stdout_position(0)
      stderr_position(0)
      shared$run_status <- "running"

      tryCatch({
        # Build command to run stamina_biome_run.sh with config
        repo_root <- dirname(getwd())
        run_script <- file.path(repo_root, "main", "pipelines", "stamina_biome_run.sh")
        config_file <- shared$current_run$config_file

        if (!file.exists(run_script)) {
          stop("Pipeline script not found at: ", run_script)
        }

        if (!file.exists(config_file)) {
          stop("Config file not found at: ", config_file)
        }

        log_buffer(c(
          paste("[INFO] Starting pipeline:", shared$current_run$pipeline),
          paste("[INFO] Run ID:", shared$current_run$run_id),
          paste("[INFO] Config:", config_file),
          paste("[INFO] Command:", run_script, "--config", config_file),
          ""
        ))

        # Start the process with output capture
        p <- sys::exec_background(
          cmd = run_script,
          args = c("--config", config_file),
          std_out = TRUE,
          std_err = TRUE
        )

        process(p)

        # Set up timer to read output
        timer <- invalidateLater(250, session)
        process_timer(timer)

        showNotification("Pipeline started successfully", type = "message")

      }, error = function(e) {
        shared$run_status <- "failed"
        log_buffer(c(log_buffer(), paste("[ERROR]", e$message)))
        showNotification(paste("Failed to start pipeline:", e$message), type = "error")
      })
    }

    # Read process output periodically
    observe({
      process_timer()

      pid <- process()
      if (is.null(pid)) return()

      tryCatch({
        # Get process status
        status <- sys::exec_status(pid, wait = FALSE)

        current_buffer <- log_buffer()

        # Read new stdout data
        if (!is.null(status$stdout) && length(status$stdout) > 0) {
          stdout_text <- rawToChar(status$stdout)
          if (nchar(stdout_text) > 0) {
            new_lines <- strsplit(stdout_text, "\n", fixed = TRUE)[[1]]
            # Filter out empty lines
            new_lines <- new_lines[nchar(new_lines) > 0]
            if (length(new_lines) > 0) {
              current_buffer <- c(current_buffer, new_lines)
            }
          }
        }

        # Read new stderr data
        if (!is.null(status$stderr) && length(status$stderr) > 0) {
          stderr_text <- rawToChar(status$stderr)
          if (nchar(stderr_text) > 0) {
            new_lines <- strsplit(stderr_text, "\n", fixed = TRUE)[[1]]
            new_lines <- new_lines[nchar(new_lines) > 0]
            if (length(new_lines) > 0) {
              current_buffer <- c(current_buffer, new_lines)
            }
          }
        }

        # Update buffer
        log_buffer(current_buffer)

        # Check if process finished
        if (!is.null(status$status)) {
          # Final read
          Sys.sleep(0.5)

          final_status <- sys::exec_status(pid, wait = FALSE)

          if (!is.null(final_status$stdout) && length(final_status$stdout) > 0) {
            stdout_text <- rawToChar(final_status$stdout)
            if (nchar(stdout_text) > 0) {
              new_lines <- strsplit(stdout_text, "\n", fixed = TRUE)[[1]]
              new_lines <- new_lines[nchar(new_lines) > 0]
              current_buffer <- c(current_buffer, new_lines)
            }
          }

          current_buffer <- c(current_buffer, "", paste("[Process finished with exit code:", status$status, "]"))
          log_buffer(current_buffer)

          if (status$status == 0) {
            shared$run_status <- "completed"
            showNotification("Pipeline completed successfully!", type = "message", duration = 10)
          } else {
            shared$run_status <- "failed"
            showNotification(paste("Pipeline failed with exit code:", status$status), type = "error", duration = 10)
          }
          process(NULL)
        }

      }, error = function(e) {
        log_buffer(c(log_buffer(), paste("[ERROR]", e$message)))
      })
    })

    # Render logs with color coding
    output$log_content <- renderUI({
      logs <- log_buffer()

      if (length(logs) == 0) {
        return(tags$p(class = "text-muted", "Waiting for pipeline output..."))
      }

      # Color code log lines
      colored_logs <- lapply(logs, function(line) {
        class_name <- if (grepl("ERROR|FAIL|FAILED", line, ignore.case = TRUE)) {
          "log-error"
        } else if (grepl("WARN|WARNING", line, ignore.case = TRUE)) {
          "log-warning"
        } else if (grepl("SUCCESS|COMPLETED|DONE|OK", line, ignore.case = TRUE)) {
          "log-success"
        } else if (grepl("INFO|STEP|STAGE", line, ignore.case = TRUE)) {
          "log-info"
        } else {
          ""
        }

        tags$div(class = class_name, line)
      })

      do.call(tagList, colored_logs)
    })

    # Clear logs
    observeEvent(input$clear_logs, {
      log_buffer(character(0))
    })

    # Refresh logs (force re-render)
    observeEvent(input$refresh_logs, {
      # Trigger reactivity
      log_buffer(log_buffer())
    })

    # Stop pipeline
    observeEvent(input$stop_run, {
      pid <- process()

      if (!is.null(pid)) {
        tryCatch({
          tools::pskill(pid)
          shared$run_status <- "stopped"
          process(NULL)
          showNotification("Pipeline stopped", type = "warning")
        }, error = function(e) {
          showNotification(paste("Failed to stop pipeline:", e$message), type = "error")
        })
      } else {
        showNotification("No running pipeline to stop", type = "warning")
      }
    })

    # View outputs
    observeEvent(input$view_outputs, {
      if (is.null(shared$current_run)) {
        showNotification("No active run to view", type = "warning")
        return()
      }

      run_dir <- file.path(dirname(getwd()), "outputs", shared$current_run$run_id)

      if (dir.exists(run_dir)) {
        system2("open", run_dir)
      } else {
        showNotification("Output directory not found", type = "error")
      }
    })

    # Return to dashboard
    observeEvent(input$return_dashboard, {
      shared$goto_page <- "Dashboard"
    })
  })
}
