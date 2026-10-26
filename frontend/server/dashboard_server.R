dashboard_server <- function(id, shared) {
  moduleServer(id, function(input, output, session) {

    get_run_status <- function(run_dir) {
      # Fast path: outputs.json presence means the pipeline completed successfully
      if (file.exists(file.path(run_dir, "outputs.json"))) {
        return("Completed")
      }

      logs_dir <- file.path(run_dir, "logs")
      if (!dir.exists(logs_dir)) return("Pending")

      log_files <- list.files(logs_dir, pattern = "\\.log$", full.names = TRUE)
      if (length(log_files) == 0) return("Pending")

      # Only read the most recently modified log to keep this fast
      log_mtimes <- file.info(log_files)$mtime
      log_file   <- log_files[which.max(log_mtimes)]

      if (file.info(log_file)$size == 0) return("Pending")

      log_content <- tryCatch(
        paste(readLines(log_file, warn = FALSE), collapse = "\n"),
        error = function(e) ""
      )

      if (grepl("CONTAINER FAILED|ERROR: Module failed|exit code: [1-9]|Pipeline failed", log_content, ignore.case = FALSE)) {
        return("Failed")
      }
      if (nchar(log_content) > 0) return("In Progress")
      return("Pending")
    }

    get_pipeline_type <- function(run_dir) {
      config_file <- file.path(run_dir, "config.json")
      effective_config_file <- file.path(run_dir, "effective_config.json")
      config_original_file <- file.path(run_dir, "config.original.json")

      for (cfg_file in c(effective_config_file, config_file, config_original_file)) {
        if (file.exists(cfg_file)) {
          config <- tryCatch({
            jsonlite::fromJSON(cfg_file)
          }, error = function(e) NULL)

          if (!is.null(config) && !is.null(config$pipeline_id)) {
            return(config$pipeline_id)
          }
        }
      }

      return("unknown")
    }

    get_sample_type <- function(run_dir) {
      config_file <- file.path(run_dir, "config.json")
      effective_config_file <- file.path(run_dir, "effective_config.json")
      config_original_file <- file.path(run_dir, "config.original.json")

      for (cfg_file in c(effective_config_file, config_file, config_original_file)) {
        if (file.exists(cfg_file)) {
          config <- tryCatch({
            jsonlite::fromJSON(cfg_file)
          }, error = function(e) NULL)

          if (!is.null(config)) {
            if (!is.null(config$specimen)) {
              return(config$specimen)
            }
            if (!is.null(config$params) && !is.null(config$params$common) && !is.null(config$params$common$specimen)) {
              return(config$params$common$specimen)
            }
          }
        }
      }

      return("other")
    }

    get_run_date <- function(run_dir) {
      dir_info <- file.info(run_dir)
      if (!is.na(dir_info$mtime)) {
        return(format(dir_info$mtime, "%Y-%m-%d %H:%M"))
      }
      return("")
    }

    # Read a batch_manifest.json's sample list, tolerant of jsonlite parsing
    # a uniform array of objects as either a data.frame or a list of lists.
    read_batch_samples <- function(manifest_path) {
      manifest <- tryCatch(jsonlite::fromJSON(manifest_path), error = function(e) NULL)
      if (is.null(manifest) || is.null(manifest$samples)) return(NULL)
      samples <- manifest$samples
      if (is.data.frame(samples)) {
        lapply(seq_len(nrow(samples)), function(i) as.list(samples[i, ]))
      } else if (is.list(samples) && length(samples) > 0) {
        samples
      } else {
        NULL
      }
    }

    # Expand one batch run directory (contains batch_manifest.json) into one
    # row per sample, reusing the exact same status/pipeline/sample_type
    # helpers as a normal run directory — just called on the nested sample
    # run_dir instead of the batch dir itself.
    expand_batch_dir <- function(batch_dir, batch_date) {
      sample_list <- read_batch_samples(file.path(batch_dir, "batch_manifest.json"))
      if (is.null(sample_list)) return(NULL)

      batch_id <- basename(batch_dir)
      rows <- lapply(sample_list, function(s) {
        sample_run_id <- if (!is.null(s$run_id)) s$run_id else "sample"
        sample_name   <- if (!is.null(s$name)) s$name else sample_run_id
        run_dir       <- if (!is.null(s$run_dir)) s$run_dir else file.path(batch_dir, sample_run_id)

        recorded_status <- if (!is.null(s$status)) s$status else ""
        status <- if (identical(recorded_status, "completed")) "Completed"
          else if (identical(recorded_status, "failed")) "Failed"
          else get_run_status(run_dir)

        data.frame(
          run_id      = sprintf("%s / %s", batch_id, sample_name),
          pipeline    = get_pipeline_type(run_dir),
          sample_type = get_sample_type(run_dir),
          status      = status,
          date        = batch_date,
          stringsAsFactors = FALSE
        )
      })
      do.call(rbind, rows)
    }

    project_stats <- reactive({
      # Poll every 5 seconds — frequent enough to catch new runs without blocking Browse
      invalidateLater(5000)

      outputs_dir <- file.path(dirname(getwd()), "outputs")

      if (!dir.exists(outputs_dir)) {
        return(list(total = 0, completed = 0, in_progress = 0, failed = 0, recent = data.frame()))
      }

      run_dirs <- list.dirs(outputs_dir, recursive = FALSE, full.names = TRUE)
      # Exclude compare output dirs (no pipeline config)
      run_dirs <- run_dirs[!grepl("/compare_[0-9]", run_dirs)]

      if (length(run_dirs) == 0) {
        return(list(total = 0, completed = 0, in_progress = 0, failed = 0, recent = data.frame()))
      }

      # Total sample count: batch dirs count their samples (cheap — just reads
      # each batch's small manifest file); non-batch dirs count as 1, same as
      # before. This does not read per-run effective_config.json/logs, so it
      # stays cheap even with many historical runs.
      total <- sum(vapply(run_dirs, function(d) {
        manifest_path <- file.path(d, "batch_manifest.json")
        if (file.exists(manifest_path)) {
          sample_list <- read_batch_samples(manifest_path)
          if (!is.null(sample_list)) return(length(sample_list))
        }
        1L
      }, integer(1)))

      # Use a single file.info() call to get all mtimes cheaply, then sort
      # so we only do expensive per-file reads for the most recent 20 runs.
      dir_info  <- file.info(run_dirs)
      mtimes    <- dir_info$mtime
      order_idx <- order(mtimes, decreasing = TRUE)
      recent_dirs <- run_dirs[order_idx[seq_len(min(20L, length(run_dirs)))]]

      runs <- lapply(recent_dirs, function(run_dir) {
        mtime <- dir_info[run_dir, "mtime"]
        date  <- if (!is.na(mtime)) format(mtime, "%Y-%m-%d %H:%M") else ""

        if (file.exists(file.path(run_dir, "batch_manifest.json"))) {
          expanded <- expand_batch_dir(run_dir, date)
          if (!is.null(expanded) && nrow(expanded) > 0) return(expanded)
        }

        data.frame(
          run_id      = basename(run_dir),
          pipeline    = get_pipeline_type(run_dir),
          sample_type = get_sample_type(run_dir),
          status      = get_run_status(run_dir),
          date        = date,
          stringsAsFactors = FALSE
        )
      })

      runs_df <- do.call(rbind, runs)

      if (is.null(runs_df) || nrow(runs_df) == 0) {
        return(list(total = 0, completed = 0, in_progress = 0, failed = 0, recent = data.frame()))
      }

      list(
        total       = total,
        completed   = sum(runs_df$status == "Completed"),
        in_progress = sum(runs_df$status == "In Progress"),
        failed      = sum(runs_df$status == "Failed"),
        recent      = head(runs_df, 10)
      )
    })

    output$total_projects <- renderText({
      as.character(project_stats()$total)
    })

    output$completed_projects <- renderText({
      as.character(project_stats()$completed)
    })

    output$in_progress_projects <- renderText({
      as.character(project_stats()$in_progress)
    })

    output$failed_projects <- renderText({
      as.character(project_stats()$failed)
    })

    output$recent_projects_table <- renderTable({
      recent <- project_stats()$recent

      if (is.null(recent) || nrow(recent) == 0) {
        return(data.frame(
          Message = "No projects found. Run a pipeline to get started!",
          check.names = FALSE
        ))
      }

      recent$Pipeline <- sapply(recent$pipeline, function(p) {
        switch(p,
          "sr_amp" = "Short Read 16S",
          "sr_meta" = "Short Read Metagenomics",
          "lr_amp" = "Long Read 16S",
          "lr_meta" = "Long Read Metagenomics",
          p
        )
      })

      data.frame(
        "Run ID" = recent$run_id,
        "Type" = recent$Pipeline,
        "Sample Type" = tools::toTitleCase(recent$sample_type),
        "Status" = recent$status,
        "Date" = recent$date,
        check.names = FALSE
      )
    }, striped = TRUE, hover = TRUE, bordered = TRUE, spacing = "s", width = "100%")

    observeEvent(input$return_to_wizard, {
      shared$show_wizard <- TRUE
    }, ignoreInit = TRUE)

    # Manual refresh trigger
    manual_refresh <- reactiveVal(0)

    observeEvent(input$refresh_dashboard, {
      manual_refresh(manual_refresh() + 1)
    }, ignoreInit = TRUE)

    # Modify project_stats to depend on manual_refresh
    observe({
      manual_refresh()
      project_stats()
    })
  })
}
