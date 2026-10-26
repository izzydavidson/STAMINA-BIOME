# ---------------------------------------------------------------------------
# Frontend postprocess hook — runs AFTER the main pipeline exits successfully.
# Does NOT modify main/ or cli/. It:
#   1. Copies FastQC HTML reports into results/qc/fastqc/
#   2. Re-runs the fixed frontend piechart.R (overwrites the legend-only output)
#   3. Runs VALENCIA R visualizations fallback if PNGs are absent
#   4. Runs results_csv.R fallback if results/tables/results.csv is absent
#   5. Mirrors results/tables/ -> final/tables/   (r_postprocess gap)
#   6. Mirrors results/valencia/ -> final/valencia/ (r_postprocess gap)
#   7. Copies re-run fixed piechart into final/plots/ (overwrites stale copy)
#   8. Copies FastQC HTML into final/qc/fastqc/
# ---------------------------------------------------------------------------
run_frontend_postprocess <- function(run_dir, pipeline_key, config_file) {
  cat("[POSTPROCESS] Starting frontend postprocess for run:", run_dir, "\n")

  repo_root    <- dirname(getwd())
  module_dir   <- file.path(run_dir, pipeline_key)
  outputs_json <- file.path(module_dir, "outputs.json")
  results_dir  <- file.path(run_dir, "results")

  # 1. Copy FastQC HTML reports -----------------------------------------------
  fastqc_src <- file.path(module_dir, "results", "fastqc")
  fastqc_dst <- file.path(results_dir, "qc", "fastqc")
  if (dir.exists(fastqc_src)) {
    dir.create(fastqc_dst, recursive = TRUE, showWarnings = FALSE)
    fastqc_files <- list.files(fastqc_src, pattern = "\\.html$", full.names = TRUE)
    if (length(fastqc_files) > 0) {
      file.copy(fastqc_files, fastqc_dst, overwrite = TRUE)
      cat("[POSTPROCESS] Copied", length(fastqc_files), "FastQC HTML file(s) ->", fastqc_dst, "\n")
    }
  } else {
    cat("[POSTPROCESS] FastQC source not found:", fastqc_src, "\n")
  }

  # 2. Re-run fixed piechart ---------------------------------------------------
  if (file.exists(outputs_json)) {
    plots_dir <- file.path(results_dir, "plots")
    dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

    frontend_piechart <- file.path(repo_root, "frontend", "pipelines", "postprocess", "r", "piechart.R")
    if (file.exists(frontend_piechart)) {
      cat("[POSTPROCESS] Re-running fixed piechart script\n")
      piechart_log <- file.path(run_dir, pipeline_key, "logs", "r_postprocess", "piechart_fixed.log")
      dir.create(dirname(piechart_log), recursive = TRUE, showWarnings = FALSE)
      piechart_params_json <- tryCatch({
        cfg  <- jsonlite::fromJSON(config_file)
        step <- cfg$postprocess$steps$piechart
        if (is.list(step) && !is.null(step$params)) {
          jsonlite::toJSON(step$params, auto_unbox = TRUE)
        } else "{}"
      }, error = function(e) "{}")
      rc <- system2(
        "Rscript",
        args   = c(frontend_piechart,
                   "--outputs_json", outputs_json,
                   "--out_dir",      plots_dir,
                   "--params_json",  piechart_params_json,
                   "--module",       pipeline_key),
        stdout = piechart_log,
        stderr = piechart_log,
        wait   = TRUE
      )
      cat("[POSTPROCESS] Piechart exit code:", rc, "\n")
    } else {
      cat("[POSTPROCESS] Frontend piechart.R not found at:", frontend_piechart, "\n")
    }
  }

  # 3. VALENCIA R visualizations fallback -------------------------------------
  # Run only if pipeline produced a VALENCIA output CSV but the R visualization
  # PNGs are missing (e.g. postprocess.steps.valencia was 0 or postprocess failed)
  valencia_csv_candidates <- c(
    file.path(module_dir, "results", "valencia", "output.csv"),
    file.path(module_dir, "results", "valencia", "valencia_assignments.csv")
  )
  valencia_dst <- file.path(results_dir, "valencia")
  has_png <- dir.exists(valencia_dst) &&
    length(list.files(valencia_dst, pattern = "\\.png$")) > 0

  if (!has_png) {
    found_csv <- Filter(file.exists, valencia_csv_candidates)
    if (length(found_csv) > 0 && file.exists(outputs_json)) {
      main_valencia <- file.path(repo_root, "main", "pipelines", "postprocess", "r", "valencia.R")
      if (file.exists(main_valencia)) {
        dir.create(valencia_dst, recursive = TRUE, showWarnings = FALSE)
        cat("[POSTPROCESS] Running VALENCIA R visualizations (fallback)\n")
        valencia_log <- file.path(run_dir, pipeline_key, "logs", "r_postprocess", "valencia_fallback.log")
        system2(
          "Rscript",
          args   = c(main_valencia,
                     "--outputs_json", outputs_json,
                     "--out_dir",      valencia_dst,
                     "--module",       pipeline_key),
          stdout = valencia_log,
          stderr = valencia_log,
          wait   = TRUE
        )
        cat("[POSTPROCESS] VALENCIA visualizations written to:", valencia_dst, "\n")
      }
    }
  }

  # 4. Abundance tables safety-net -----------------------------------------------
  # Run results_csv.R if results/tables/results.csv is absent or suspiciously small
  # (< 100 bytes means something went wrong with the postprocess step)
  tables_dst  <- file.path(results_dir, "tables")
  tables_file <- file.path(tables_dst, "results.csv")
  tables_missing <- !file.exists(tables_file) ||
    (file.exists(tables_file) && file.info(tables_file)$size < 100)

  if (tables_missing && file.exists(outputs_json)) {
    main_results_csv <- file.path(repo_root, "main", "pipelines", "postprocess", "r", "results_csv.R")
    if (file.exists(main_results_csv)) {
      dir.create(tables_dst, recursive = TRUE, showWarnings = FALSE)
      cat("[POSTPROCESS] Running results_csv.R (tables safety-net)\n")
      tables_log <- file.path(run_dir, pipeline_key, "logs", "r_postprocess", "results_csv_fallback.log")
      dir.create(dirname(tables_log), recursive = TRUE, showWarnings = FALSE)
      rc <- system2(
        "Rscript",
        args   = c(main_results_csv,
                   "--outputs_json", outputs_json,
                   "--out_dir",      tables_dst,
                   "--module",       pipeline_key),
        stdout = tables_log,
        stderr = tables_log,
        wait   = TRUE
      )
      cat("[POSTPROCESS] results_csv exit code:", rc, "\n")
    } else {
      cat("[POSTPROCESS] results_csv.R not found at:", main_results_csv, "\n")
    }
  } else if (!tables_missing) {
    cat("[POSTPROCESS] Tables already present, skipping results_csv safety-net\n")
  }

  final_dir <- file.path(run_dir, "final_results")

  # 5. Mirror results/tables/ -> final/tables/ ------------------------------------
  # r_postprocess writes tables to results/ but never promotes them to final/.
  tables_src_files <- list.files(tables_dst, full.names = TRUE)
  if (length(tables_src_files) > 0) {
    final_tables <- file.path(final_dir, "tables")
    dir.create(final_tables, recursive = TRUE, showWarnings = FALSE)
    file.copy(tables_src_files, final_tables, overwrite = TRUE)
    cat("[POSTPROCESS] Mirrored", length(tables_src_files), "table file(s) -> final/tables/\n")
  }

  # 6. Mirror results/valencia/ -> final/valencia/ --------------------------------
  # r_postprocess copies Valencia CSVs to results/valencia/ and the R script
  # writes PNGs there, but none of it is promoted to final/.
  if (dir.exists(valencia_dst)) {
    valencia_src_files <- list.files(valencia_dst, full.names = TRUE)
    if (length(valencia_src_files) > 0) {
      final_valencia <- file.path(final_dir, "valencia")
      dir.create(final_valencia, recursive = TRUE, showWarnings = FALSE)
      file.copy(valencia_src_files, final_valencia, overwrite = TRUE)
      cat("[POSTPROCESS] Mirrored", length(valencia_src_files), "valencia file(s) -> final/valencia/\n")
    }
  }

  # 7. Copy re-run fixed piechart into final/plots/ --------------------------------
  # Step 2 overwrites results/plots/piechart_genus.png with the fixed version,
  # but final/plots/ still has the copy that r_postprocess made before our fix.
  fixed_pie <- file.path(results_dir, "plots", "piechart_genus.png")
  if (file.exists(fixed_pie)) {
    final_plots <- file.path(final_dir, "plots")
    dir.create(final_plots, recursive = TRUE, showWarnings = FALSE)
    file.copy(fixed_pie, final_plots, overwrite = TRUE)
    cat("[POSTPROCESS] Updated final/plots/ with fixed piechart_genus.png\n")
  }

  # 8. Copy FastQC HTML into final/qc/fastqc/ -------------------------------------
  # Step 1 copies FastQC to results/qc/fastqc/ but not to final/qc/fastqc/.
  if (dir.exists(fastqc_dst)) {
    fastqc_final_dst <- file.path(final_dir, "qc", "fastqc")
    fastqc_html_files <- list.files(fastqc_dst, pattern = "\\.html$", full.names = TRUE)
    if (length(fastqc_html_files) > 0) {
      dir.create(fastqc_final_dst, recursive = TRUE, showWarnings = FALSE)
      file.copy(fastqc_html_files, fastqc_final_dst, overwrite = TRUE)
      cat("[POSTPROCESS] Copied", length(fastqc_html_files), "FastQC HTML file(s) -> final/qc/fastqc/\n")
    }
  }

  cat("[POSTPROCESS] Frontend postprocess complete\n")
}

pipeline_modal_server <- function(id, shared) {
  moduleServer(id, function(input, output, session) {

    pipeline_process <- reactiveVal(NULL)
    start_time <- reactiveVal(NULL)
    run_dir <- reactiveVal(NULL)
    pipeline_key <- reactiveVal(NULL)
    log_offsets <- reactiveVal(list())
    combined_log_buffer <- reactiveVal(character())

    # --- Batch queue state (multi-sample runs) ---
    # batch_state$index == 0L means "not currently running a batch" — every code
    # path below that checks batch_state$index > 0L is additive; single-sample
    # runs (shared$current_run set directly, shared$current_batch absent) never
    # touch this and behave exactly as before.
    batch_state <- reactiveValues(
      batch_id = NULL, pipeline = NULL, queue = list(), index = 0L, results = list()
    )

    pipeline_label_for <- function(pipeline_id) {
      switch(pipeline_id,
        "sr_amp" = "Short Read 16S Amplicon",
        "sr_meta" = "Short Read Metagenomics",
        "lr_amp" = "Long Read 16S Amplicon",
        "lr_meta" = "Long Read Metagenomics",
        pipeline_id
      )
    }

    show_run_modal <- function(title, pipeline_id, config_file) {
      config_json <- tryCatch({
        jsonlite::toJSON(jsonlite::fromJSON(config_file), pretty = TRUE, auto_unbox = TRUE)
      }, error = function(e) {
        paste("Error reading config:", e$message)
      })

      showModal(pipeline_modal_ui(title, pipeline_label_for(pipeline_id), config_json, session))
    }

    # Start (or restart, for the next queued sample) execution for one batch sample.
    start_batch_sample <- function(idx) {
      run_info <- batch_state$queue[[idx]]
      n_total  <- length(batch_state$queue)

      shared$current_run <- list(
        run_id      = run_info$run_id,
        pipeline    = run_info$pipeline,
        config_file = run_info$config_file,
        run_name    = run_info$sample_name,
        sample_type = NULL
      )

      modal_title <- sprintf("%s  ·  Sample %d of %d: %s",
        batch_state$batch_id, idx, n_total, run_info$sample_name)
      show_run_modal(modal_title, run_info$pipeline, run_info$config_file)

      execute_pipeline()
    }

    # Called once the last queued sample finishes: write batch_manifest.json and,
    # if >=2 samples succeeded, auto-invoke `stamina-biome compare` across their run dirs
    # (reuses the existing compare CLI subcommand — no new plotting/report code).
    finish_batch <- function() {
      results <- batch_state$results
      n_ok <- sum(vapply(results, function(r) r$status == "completed", logical(1)))

      repo_root   <- dirname(getwd())
      batch_outdir <- file.path(repo_root, "outputs", batch_state$batch_id)

      comparison_dir <- NULL
      if (n_ok >= 2) {
        ok_dirs <- vapply(Filter(function(r) r$status == "completed", results), `[[`, character(1), "run_dir")
        stamina_biome_bin <- file.path(repo_root, "stamina-biome")
        compare_args <- c("compare")
        for (d in ok_dirs) compare_args <- c(compare_args, "--run", d)
        compare_args <- c(compare_args, "--outdir", batch_outdir, "--name", "comparison")

        tryCatch({
          compare_log <- file.path(batch_outdir, "comparison.log")
          dir.create(batch_outdir, recursive = TRUE, showWarnings = FALSE)
          processx::run(stamina_biome_bin, compare_args, wd = repo_root,
                         stdout = compare_log, stderr = compare_log, error_on_status = FALSE)
          comparison_dir <- file.path(batch_outdir, "comparison")
          cat("[INFO] Batch comparison written to:", comparison_dir, "\n")
        }, error = function(e) {
          cat("[WARNING] Batch comparison failed:", e$message, "(sample results are still valid)\n")
        })
      }

      tryCatch({
        dir.create(batch_outdir, recursive = TRUE, showWarnings = FALSE)
        manifest <- list(
          batch_id = batch_state$batch_id,
          pipeline = batch_state$pipeline,
          samples  = results,
          comparison_dir = comparison_dir
        )
        jsonlite::write_json(manifest, file.path(batch_outdir, "batch_manifest.json"),
                              auto_unbox = TRUE, pretty = TRUE)
      }, error = function(e) {
        cat("[WARNING] Could not write batch_manifest.json:", e$message, "\n")
      })

      showNotification(
        sprintf("Batch complete: %d/%d samples succeeded.", n_ok, length(results)),
        type = if (n_ok == length(results)) "message" else "warning",
        duration = 15
      )

      batch_state$index <- 0L
      shared$run_status <- if (n_ok == length(results)) "completed" else "failed"
    }

    observeEvent(shared$run_status, {
      if (shared$run_status != "ready") return()

      if (!is.null(shared$current_batch)) {
        cat("[DEBUG] Starting batch run:", shared$current_batch$batch_id,
            "(", length(shared$current_batch$runs), "samples )\n")
        batch_state$batch_id <- shared$current_batch$batch_id
        batch_state$pipeline <- shared$current_batch$pipeline
        batch_state$queue    <- shared$current_batch$runs
        batch_state$index    <- 1L
        batch_state$results  <- list()
        shared$current_batch <- NULL  # consume the trigger

        start_batch_sample(1L)
        return()
      }

      if (!is.null(shared$current_run)) {
        cat("[DEBUG] Showing pipeline modal\n")
        show_run_modal(shared$current_run$run_id, shared$current_run$pipeline, shared$current_run$config_file)
        execute_pipeline()
      }
    })

    execute_pipeline <- function() {
      cat("[DEBUG] Starting pipeline execution\n")

      start_time(Sys.time())
      shared$run_status <- "running"
      combined_log_buffer(character())
      log_offsets(list())

      tryCatch({
        repo_root <- dirname(getwd())
        # Use the frontend wrapper: calls stamina_biome_run.sh then runs
        # frontend_postprocess.R on success — guaranteed to run regardless
        # of Shiny app restarts between launch and completion.
        run_script <- file.path(repo_root, "frontend", "run_with_postprocess.sh")
        config_file <- shared$current_run$config_file

        if (!file.exists(run_script)) {
          stop("Pipeline wrapper script not found at: ", run_script)
        }

        if (!file.exists(config_file)) {
          stop("Config file not found at: ", config_file)
        }

        config <- jsonlite::fromJSON(config_file)
        output_dir <- config$run$work_dir

        sanitized_run_id <- tolower(shared$current_run$run_id)
        sanitized_run_id <- gsub("[^a-z0-9_-]", "", sanitized_run_id)
        sanitized_run_id <- gsub("^-+|-+$", "", sanitized_run_id)

        expected_run_dir <- file.path(output_dir, sanitized_run_id)
        expected_run_dir_abs <- normalizePath(expected_run_dir, mustWork = FALSE)

        run_dir(expected_run_dir_abs)
        pipeline_key(shared$current_run$pipeline)

        cat("[DEBUG] Run directory:", expected_run_dir_abs, "\n")
        cat("[DEBUG] Pipeline key:", shared$current_run$pipeline, "\n")

        # Pre-create the run's logs/ directory and open wrapper.log BEFORE
        # starting the process. This guarantees wrapper output is captured
        # even when the pipeline fails immediately (e.g. exit 125, Docker
        # error) before the pipeline itself creates any files.
        #
        # NOTE: stdout = "file_path" is a FILE redirect — completely different
        # from stdout = "|" (pipe). File writes never block regardless of how
        # much output the process produces, so the original pipe-buffer concern
        # does NOT apply here. proc$is_alive() / proc$get_exit_status() still
        # work via PID, not pipe.
        wrapper_logs_dir <- file.path(expected_run_dir_abs, "logs")
        dir.create(wrapper_logs_dir, recursive = TRUE, showWarnings = FALSE)
        wrapper_log_path <- file.path(wrapper_logs_dir, "wrapper.log")
        writeLines(
          paste0("[WRAPPER] Pipeline starting at ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                 "\n[WRAPPER] Run ID: ", shared$current_run$run_id,
                 "\n[WRAPPER] Pipeline: ", shared$current_run$pipeline,
                 "\n[WRAPPER] Config: ", config_file),
          wrapper_log_path
        )

        # DORADO_MODEL_DIR tells the pipeline where to find Dorado models.
        # tools/ is at the repo root, OUTSIDE main/. Docker mounts main/ at /work,
        # so /work/tools/ does NOT exist. However run_in_container.sh mounts
        # /Users:/Users (macOS) so the host absolute path is accessible in the container.
        proc_env <- c(
          Sys.getenv(),
          DORADO_MODEL_DIR = file.path(repo_root, "tools", "models", "dorado")
        )

        proc <- processx::process$new(
          command = run_script,
          args = c("--config", config_file),
          wd = repo_root,
          stdout = wrapper_log_path,
          stderr = "2>&1",   # merge stderr into stdout → both go to wrapper.log
          env = proc_env,
          supervise = FALSE   # FALSE = wrapper outlives Shiny restarts;
                              # supervise=TRUE was killing the wrapper on restart,
                              # so frontend_postprocess.R never ran after Docker finished.
        )

        pipeline_process(proc)
        cat("[DEBUG] Pipeline process started with PID:", proc$get_pid(), "\n")

      }, error = function(e) {
        shared$run_status <- "failed"
        batch_state$index <- 0L  # abort the batch rather than leaving stale queue state
        cat("[ERROR]", e$message, "\n")
      })
    }

    output$modal_status_badge <- renderUI({
      status <- shared$run_status

      if (status == "running") {
        tags$span(
          class = "badge bg-warning",
          style = "font-size: 1rem; padding: 0.5rem 1rem;",
          icon("spinner", class = "fa-spin"), " PIPELINE IN PROGRESS"
        )
      } else if (status == "completed") {
        tags$span(
          class = "badge bg-success",
          style = "font-size: 1rem; padding: 0.5rem 1rem;",
          icon("check-circle"), " PIPELINE COMPLETE!"
        )
      } else if (status == "failed") {
        tags$span(
          class = "badge bg-danger",
          style = "font-size: 1rem; padding: 0.5rem 1rem;",
          icon("times-circle"), " PIPELINE FAILED"
        )
      } else {
        tags$span(
          class = "badge bg-secondary",
          style = "font-size: 1rem; padding: 0.5rem 1rem;",
          status
        )
      }
    })

    output$elapsed_time <- renderText({
      invalidateLater(1000, session)

      st <- start_time()
      if (is.null(st)) return("--:--:--")

      elapsed <- as.numeric(difftime(Sys.time(), st, units = "secs"))
      hours <- floor(elapsed / 3600)
      mins <- floor((elapsed %% 3600) / 60)
      secs <- floor(elapsed %% 60)

      sprintf("%02d:%02d:%02d", hours, mins, secs)
    })

    observe({
      invalidateLater(500, session)

      rd <- run_dir()
      pk <- pipeline_key()

      if (is.null(rd) || is.null(pk)) return()

      logs <- discover_run_logs(rd, pk)

      if (length(logs) > 0) {
        offsets <- log_offsets()
        current_buffer <- combined_log_buffer()

        for (log in logs) {
          log_path <- log$path
          log_name <- log$name

          if (!file.exists(log_path)) next

          if (is.null(offsets[[log_name]])) {
            offsets[[log_name]] <- 0
          }

          current_size <- file.info(log_path)$size
          last_offset <- offsets[[log_name]]

          if (current_size > last_offset) {
            tryCatch({
              con <- file(log_path, "r")
              seek(con, last_offset)
              new_lines <- readLines(con, warn = FALSE)
              close(con)

              if (length(new_lines) > 0) {
                timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
                prefixed_lines <- paste0("[", timestamp, "] [", log$display_name, "] ", new_lines)
                current_buffer <- c(current_buffer, prefixed_lines)
              }

              offsets[[log_name]] <- current_size
            }, error = function(e) {
              cat("[ERROR] Reading log", log_name, ":", e$message, "\n")
            })
          }
        }

        log_offsets(offsets)
        combined_log_buffer(current_buffer)
      }

      proc <- pipeline_process()
      if (!is.null(proc) && !proc$is_alive()) {
        cat("[DEBUG] Pipeline process has exited\n")

        Sys.sleep(1)

        logs <- discover_run_logs(rd, pk)
        if (length(logs) > 0) {
          offsets <- log_offsets()
          current_buffer <- combined_log_buffer()

          for (log in logs) {
            log_path <- log$path
            if (!file.exists(log_path)) next

            final_size <- file.info(log_path)$size
            last_offset <- offsets[[log$name]]
            if (is.null(last_offset)) last_offset <- 0

            if (final_size > last_offset) {
              tryCatch({
                con <- file(log_path, "r")
                seek(con, last_offset)
                final_lines <- readLines(con, warn = FALSE)
                close(con)

                if (length(final_lines) > 0) {
                  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
                  prefixed_lines <- paste0("[", timestamp, "] [", log$display_name, "] ", final_lines)
                  current_buffer <- c(current_buffer, prefixed_lines)
                }

                offsets[[log$name]] <- final_size
              }, error = function(e) {
                cat("[ERROR] Reading final log", log$name, ":", e$message, "\n")
              })
            }
          }

          log_offsets(offsets)
          combined_log_buffer(current_buffer)
        }

        exit_code <- tryCatch({
          proc$get_exit_status()
        }, error = function(e) -1)

        if (exit_code == 0) {
          # Belt-and-suspenders: directly copy tables/valencia/plots/qc into
          # final/ using file.copy() in-process.  system2() calls inside the
          # wrapper's Rscript subprocess can fail silently when run as a
          # grandchild of processx (pipe buffer / graphics device inheritance
          # issues).  This in-process copy is guaranteed to work because it
          # runs directly in the Shiny R session with no subprocess overhead.
          tryCatch({
            rd_val <- run_dir()
            pk_val <- pipeline_key()
            if (!is.null(rd_val) && !is.null(pk_val)) {
              results_d <- file.path(rd_val, "results")
              final_d   <- file.path(rd_val, "final_results")
              module_d  <- file.path(rd_val, pk_val)

              # tables + valencia: copy everything
              for (cat_name in c("tables", "valencia")) {
                src <- file.path(results_d, cat_name)
                dst <- file.path(final_d,   cat_name)
                if (dir.exists(src)) {
                  fs <- list.files(src, full.names = TRUE)
                  if (length(fs) > 0) {
                    dir.create(dst, recursive = TRUE, showWarnings = FALSE)
                    file.copy(fs, dst, overwrite = TRUE)
                    cat("[INFO] In-process copy:", length(fs), "file(s) ->", dst, "\n")
                  }
                }
              }

              # plots: images only; CSV data files go to tables/
              plot_src <- file.path(results_d, "plots")
              plot_dst <- file.path(final_d,   "plots")
              tbl_dst  <- file.path(final_d,   "tables")
              if (dir.exists(plot_src)) {
                img_fs <- list.files(plot_src, pattern = "\\.(png|pdf|svg)$", full.names = TRUE)
                csv_fs <- list.files(plot_src, pattern = "\\.(csv|tsv)$",     full.names = TRUE)
                if (length(img_fs) > 0) {
                  dir.create(plot_dst, recursive = TRUE, showWarnings = FALSE)
                  file.copy(img_fs, plot_dst, overwrite = TRUE)
                }
                if (length(csv_fs) > 0) {
                  dir.create(tbl_dst, recursive = TRUE, showWarnings = FALSE)
                  file.copy(csv_fs, tbl_dst, overwrite = TRUE)
                }
                stale <- list.files(plot_dst, pattern = "\\.(csv|tsv)$", full.names = TRUE)
                if (length(stale) > 0) file.remove(stale)
                cat("[INFO] In-process plots: images ->", plot_dst, "| CSVs ->", tbl_dst, "\n")
              }

              # qc/: multiqc (preserve sub-directories)
              qc_src <- file.path(results_d, "qc")
              qc_dst <- file.path(final_d,   "qc")
              if (dir.exists(qc_src)) {
                fs <- list.files(qc_src, full.names = TRUE, recursive = TRUE)
                for (f in fs) {
                  rel   <- substring(f, nchar(qc_src) + 2)
                  d_dst <- file.path(qc_dst, dirname(rel))
                  dir.create(d_dst, recursive = TRUE, showWarnings = FALSE)
                  file.copy(f, file.path(d_dst, basename(f)), overwrite = TRUE)
                }
                cat("[INFO] In-process qc:", length(fs), "file(s) ->", qc_dst, "\n")
              }

              # qc/fastqc/: FastQC HTML from <module>/results/fastqc/
              fqc_src <- file.path(module_d, "results", "fastqc")
              fqc_dst <- file.path(final_d,  "qc", "fastqc")
              if (dir.exists(fqc_src)) {
                fqc_fs <- list.files(fqc_src, pattern = "\\.html$", full.names = TRUE)
                if (length(fqc_fs) > 0) {
                  dir.create(fqc_dst, recursive = TRUE, showWarnings = FALSE)
                  file.copy(fqc_fs, fqc_dst, overwrite = TRUE)
                  cat("[INFO] In-process FastQC:", length(fqc_fs), "HTML ->", fqc_dst, "\n")
                }
              }
            }
          }, error = function(e) {
            cat("[WARNING] In-process final/ copy failed:", e$message, "\n")
          })

          # ── Additional output directory copy ──────────────────────────────
          # If the user chose an extra output dir (SR or LR module), copy the
          # entire run folder there.  Original in STAMINA-BIOME/outputs/ is untouched.
          if (!is.null(shared$additional_output_dir) &&
              nchar(trimws(shared$additional_output_dir)) > 0) {
            tryCatch({
              rd_val  <- run_dir()
              extra   <- trimws(shared$additional_output_dir)
              dest    <- file.path(extra, basename(rd_val))
              if (!dir.exists(extra)) {
                stop("Destination directory does not exist: ", extra)
              }
              # Remove stale destination so file.copy gets a clean slate
              if (dir.exists(dest)) unlink(dest, recursive = TRUE)
              copy_ok <- file.copy(rd_val, extra, recursive = TRUE, overwrite = TRUE)
              if (!isTRUE(copy_ok)) {
                stop("file.copy() returned FALSE (source: ", rd_val, ")")
              }
              cat("[INFO] Copied run folder to additional output:", dest, "\n")
              showNotification(
                paste("Run folder copied to", dest),
                type = "message", duration = 8
              )
            }, error = function(e) {
              cat("[WARNING] Additional output dir copy failed:", e$message, "\n")
              showNotification(
                paste("Could not copy run folder to additional output dir:", e$message),
                type = "warning", duration = 15
              )
            })
          }

          sample_ok <- TRUE
          cat("[INFO] Pipeline complete\n")
        } else {
          sample_ok <- FALSE
          cat("[INFO] Pipeline failed with exit code:", exit_code, "\n")
        }

        if (batch_state$index > 0L) {
          # ---- Batch mode: record this sample's result, then advance or finish ----
          idx <- batch_state$index
          run_info <- batch_state$queue[[idx]]
          batch_state$results[[idx]] <- list(
            name    = run_info$sample_name,
            run_id  = run_info$run_id,
            run_dir = run_dir(),
            status  = if (sample_ok) "completed" else "failed"
          )

          pipeline_process(NULL)

          if (idx < length(batch_state$queue)) {
            # More samples queued — close this sample's modal and open the next.
            removeModal()
            batch_state$index <- idx + 1L
            start_batch_sample(batch_state$index)
          } else {
            # Last sample — leave its modal open (same as single-run completion)
            # so the user sees the final status badge and Return-to-Dashboard button.
            finish_batch()
          }
        } else {
          # ---- Single-sample mode: unchanged behavior ----
          shared$run_status <- if (sample_ok) "completed" else "failed"
          pipeline_process(NULL)
        }
      }
    })

    # -------------------------------------------------------------------------
    # Continuous results -> final/ sync.
    # Runs every 3 s whenever run_dir and pipeline_key are set.
    # Independent of process state, exit codes, Shiny restarts, or timing.
    # Plain file.copy — no subprocesses, no R library locks.
    # Idempotent: overwrite = TRUE so re-running is always safe.
    # -------------------------------------------------------------------------
    observe({
      invalidateLater(3000, session)

      rd <- run_dir()
      pk <- pipeline_key()
      if (is.null(rd) || is.null(pk)) return()

      tryCatch({
        results_d <- file.path(rd, "results")
        final_d   <- file.path(rd, "final_results")
        module_d  <- file.path(rd, pk)

        # tables: copy everything
        for (cat_name in c("tables", "valencia")) {
          src <- file.path(results_d, cat_name)
          dst <- file.path(final_d, cat_name)
          if (dir.exists(src)) {
            fs <- list.files(src, full.names = TRUE)
            if (length(fs) > 0) {
              dir.create(dst, recursive = TRUE, showWarnings = FALSE)
              file.copy(fs, dst, overwrite = TRUE)
            }
          }
        }

        # plots: images only (.png/.pdf/.svg); CSV data files go to tables/
        plot_src <- file.path(results_d, "plots")
        plot_dst <- file.path(final_d, "plots")
        tbl_dst  <- file.path(final_d, "tables")
        if (dir.exists(plot_src)) {
          img_fs <- list.files(plot_src, pattern = "\\.(png|pdf|svg)$", full.names = TRUE)
          csv_fs <- list.files(plot_src, pattern = "\\.(csv|tsv)$",     full.names = TRUE)
          if (length(img_fs) > 0) {
            dir.create(plot_dst, recursive = TRUE, showWarnings = FALSE)
            file.copy(img_fs, plot_dst, overwrite = TRUE)
          }
          if (length(csv_fs) > 0) {
            dir.create(tbl_dst, recursive = TRUE, showWarnings = FALSE)
            file.copy(csv_fs, tbl_dst, overwrite = TRUE)
          }
          # purge any stale CSVs that ended up in final/plots/
          stale <- list.files(plot_dst, pattern = "\\.(csv|tsv)$", full.names = TRUE)
          if (length(stale) > 0) file.remove(stale)
        }

        # qc: multiqc from results/qc/ (preserve sub-directories)
        qc_src <- file.path(results_d, "qc")
        qc_dst <- file.path(final_d, "qc")
        if (dir.exists(qc_src)) {
          fs <- list.files(qc_src, full.names = TRUE, recursive = TRUE)
          for (f in fs) {
            rel   <- substring(f, nchar(qc_src) + 2)
            d_dst <- file.path(qc_dst, dirname(rel))
            dir.create(d_dst, recursive = TRUE, showWarnings = FALSE)
            file.copy(f, file.path(d_dst, basename(f)), overwrite = TRUE)
          }
        }

        # qc: FastQC HTML from <module>/results/fastqc/ (main never promotes these)
        fqc_src <- file.path(module_d, "results", "fastqc")
        fqc_dst <- file.path(final_d, "qc", "fastqc")
        if (dir.exists(fqc_src)) {
          fqc_fs <- list.files(fqc_src, pattern = "\\.html$", full.names = TRUE)
          if (length(fqc_fs) > 0) {
            dir.create(fqc_dst, recursive = TRUE, showWarnings = FALSE)
            file.copy(fqc_fs, fqc_dst, overwrite = TRUE)
          }
        }
      }, error = function(e) {})
    })

    output$pipeline_log_stream <- renderUI({
      lines <- combined_log_buffer()

      if (length(lines) == 0) {
        return(HTML("<span style='color: #888888;'>Waiting for logs...</span>"))
      }

      colored_lines <- sapply(lines, function(line) {
        # Strip ANSI color codes (e.g., [31m, [1m, [0m) for clean display
        # LR pipelines use ANSI codes; SR pipelines don't
        clean_line <- gsub("\033\\[[0-9;]+m", "", line)  # \033 = ESC character
        clean_line <- gsub("\\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGKH]", "", clean_line)  # fallback for literal codes

        style <- if (grepl("ERROR", clean_line, ignore.case = TRUE)) {
          "color: #ff4d4d; font-weight: bold;"
        } else if (grepl("WARNING", clean_line, ignore.case = TRUE)) {
          "color: #ffa500; font-weight: bold;"
        } else if (grepl("succeeded", clean_line, ignore.case = TRUE)) {
          "color: #00cc66; font-weight: bold;"
        } else if (grepl("Started|started", clean_line)) {
          "color: #00e5ff;"
        } else {
          "color: #888888;"
        }

        escaped_line <- htmltools::htmlEscape(clean_line)
        paste0("<span style='", style, "'>", escaped_line, "</span>")
      }, USE.NAMES = FALSE)

      HTML(paste(colored_lines, collapse = "<br>"))
    })

    output$cancel_run_btn <- renderUI({
      if (shared$run_status == "running") {
        actionButton(session$ns("cancel_run"), "Cancel Run",
                     icon  = icon("stop"),
                     class = "btn btn-danger")
      }
    })

    observeEvent(input$cancel_run, {
      proc <- pipeline_process()

      if (!is.null(proc) && proc$is_alive()) {
        cat("[DEBUG] Cancelling pipeline (PID:", proc$get_pid(), ")\n")

        tryCatch({
          proc$kill_tree()
          shared$run_status <- "cancelled"
          pipeline_process(NULL)
          # Stop the batch here — don't auto-advance to the next queued sample,
          # and don't leave stale batch state that would contaminate the next run.
          batch_state$index <- 0L
        }, error = function(e) {
          cat("[ERROR] Failed to cancel:", e$message, "\n")
        })
      }
    })

    observeEvent(input$return_dashboard, {
      cat("[DEBUG] Returning to dashboard\n")
      removeModal()
      shared$goto_page <- "Dashboard"
      shared$run_status <- "idle"
      pipeline_process(NULL)
      batch_state$index <- 0L
    })
  })
}
