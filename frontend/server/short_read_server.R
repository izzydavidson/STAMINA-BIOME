short_read_server <- function(id, shared) {
  moduleServer(id, function(input, output, session) {

    ns <- session$ns

    # ── Native OS file/dir pickers via osascript ──────────────────────────────

    observeEvent(input$input_path_browse_file, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "input_path", value = path)
    })

    observeEvent(input$input_path_browse_dir, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "input_path", value = path)
    })

    observeEvent(input$input_r1_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "input_r1", value = path)
    })

    observeEvent(input$input_r2_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "input_r2", value = path)
    })

    observeEvent(input$kraken_db_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "kraken_db", value = path)
    })

    observeEvent(input$external_db_dir_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "external_db_dir", value = path)
    })

    # ── Site-specific Kraken2 defaults ───────────────────────────────────────────
    # Gut/skin: conf=0.03, MHG=4 | oral: conf=0.04, MHG=4 | vaginal: conf=0.02, MHG=2
    observeEvent(input$sample_type, {
      defaults <- switch(input$sample_type,
        vaginal = list(conf = 0.02, mhg = 2L),
        gut     = list(conf = 0.03, mhg = 4L),
        oral    = list(conf = 0.04, mhg = 4L),
        skin    = list(conf = 0.03, mhg = 4L),
        other   = list(conf = 0.05, mhg = 2L)
      )
      updateNumericInput(session, "kraken_confidence",     value = defaults$conf)
      updateNumericInput(session, "kraken_min_hit_groups", value = defaults$mhg)
    }, ignoreInit = FALSE)

    observeEvent(input$extra_output_dir_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) {
        updateTextInput(session, "extra_output_dir", value = path)
        shared$additional_output_dir <- path
      }
    })

    # --- Barcode mapping state ---
    n_barcodes <- reactiveVal(0L)

    # Reset rows when demultiplex is unchecked
    observeEvent(input$demultiplex, {
      if (!isTRUE(input$demultiplex)) n_barcodes(0L)
    }, ignoreInit = TRUE)

    # Add a barcode row (capped at 96 for short-read — no kit-specific limit)
    observeEvent(input$add_barcode_row, {
      cur <- n_barcodes()
      if (cur < 96L) n_barcodes(cur + 1L)
    })

    # Remove the last barcode row
    observeEvent(input$remove_barcode_row, {
      cur <- n_barcodes()
      if (cur > 0L) n_barcodes(cur - 1L)
    })

    # Render dynamic barcode rows
    output$barcode_map_rows <- renderUI({
      n <- n_barcodes()
      if (n == 0L) return(NULL)
      tagList(lapply(seq_len(n), function(i) {
        bc_id <- sprintf("barcode%02d", i)
        div(
          class = "row mb-2 align-items-center",
          div(class = "col-md-3", tags$code(bc_id)),
          div(
            class = "col-md-9",
            textInput(
              ns(paste0("bc_name_", i)), NULL,
              placeholder = "Sample name",
              value = isolate(input[[paste0("bc_name_", i)]] %||% "")
            )
          )
        )
      }))
    })

    # --- Multi-sample batch state (independent samples, each with own R1/R2) ---
    n_samples <- reactiveVal(0L)
    MAX_BATCH_SAMPLES <- 50L

    observeEvent(input$add_sample_row, {
      cur <- n_samples()
      if (cur < MAX_BATCH_SAMPLES) n_samples(cur + 1L)
    })

    observeEvent(input$remove_sample_row, {
      cur <- n_samples()
      if (cur > 0L) n_samples(cur - 1L)
    })

    # Pre-register file-browse observers for every possible extra-sample row
    # (Shiny observers on not-yet-rendered inputs are inert until the input exists).
    lapply(seq_len(MAX_BATCH_SAMPLES), function(i) {
      local({
        idx <- i
        observeEvent(input[[paste0("smp_r1_browse_", idx)]], {
          path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
          if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, paste0("smp_r1_", idx), value = path)
        })
        observeEvent(input[[paste0("smp_r2_browse_", idx)]], {
          path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
          if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, paste0("smp_r2_", idx), value = path)
        })
        observeEvent(input[[paste0("smp_path_browse_", idx)]], {
          path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
          if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, paste0("smp_path_", idx), value = path)
        })
      })
    })

    # Sample 1's name field only appears once a second sample has been added —
    # invisible (and behavior-unchanged) in the default single-sample view.
    output$sample1_name_row <- renderUI({
      if (n_samples() == 0L) return(NULL)
      div(
        class = "mb-3",
        tags$label(class = "form-label", "Sample Name (Sample 1)"),
        textInput(ns("sample1_name"), NULL,
          placeholder = "e.g., Patient001",
          value = isolate(input$sample1_name %||% "")
        )
      )
    })

    # Render Sample 2..N rows: Name + (R1/R2 or single path, matching paired_end)
    output$extra_sample_rows <- renderUI({
      n <- n_samples()
      if (n == 0L) return(NULL)
      paired <- isTRUE(input$paired_end)
      tagList(lapply(seq_len(n), function(i) {
        idx <- i + 1L
        div(
          class = "card mb-3",
          div(
            class = "card-body",
            h5(sprintf("Sample %d", idx)),
            div(
              class = "mb-3",
              tags$label(class = "form-label", "Sample Name"),
              textInput(ns(paste0("smp_name_", i)), NULL,
                placeholder = sprintf("e.g., Patient%03d", idx),
                value = isolate(input[[paste0("smp_name_", i)]] %||% "")
              )
            ),
            if (paired) {
              div(
                class = "row",
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Forward Reads (R1)"),
                  div(
                    class = "file-browse-group",
                    div(
                      class = "drop-zone",
                      div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                      actionButton(ns(paste0("smp_r1_browse_", i)), "Browse",
                        class = "btn btn-outline-secondary")
                    ),
                    textInput(ns(paste0("smp_r1_", i)), NULL,
                      placeholder = "/path/to/sample_R1.fastq.gz", width = "100%")
                  )
                ),
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Reverse Reads (R2)"),
                  div(
                    class = "file-browse-group",
                    div(
                      class = "drop-zone",
                      div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                      actionButton(ns(paste0("smp_r2_browse_", i)), "Browse",
                        class = "btn btn-outline-secondary")
                    ),
                    textInput(ns(paste0("smp_r2_", i)), NULL,
                      placeholder = "/path/to/sample_R2.fastq.gz", width = "100%")
                  )
                )
              )
            } else {
              div(
                class = "mb-3",
                tags$label(class = "form-label", "FASTQ File or Directory"),
                div(
                  class = "file-browse-group",
                  div(
                    class = "drop-zone",
                    div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                    actionButton(ns(paste0("smp_path_browse_", i)), "Browse",
                      class = "btn btn-outline-secondary")
                  ),
                  textInput(ns(paste0("smp_path_", i)), NULL,
                    placeholder = "/path/to/file.fastq.gz", width = "100%")
                )
              )
            }
          )
        )
      }))
    })

    # Collect Sample 2..N as a list of {name, input_r1, input_r2, input_path}
    get_extra_samples <- reactive({
      n <- n_samples()
      if (n == 0L) return(list())
      paired <- isTRUE(input$paired_end)
      lapply(seq_len(n), function(i) {
        nm <- trimws(input[[paste0("smp_name_", i)]] %||% "")
        if (paired) {
          list(
            name = nm,
            input_r1 = trimws(input[[paste0("smp_r1_", i)]] %||% ""),
            input_r2 = trimws(input[[paste0("smp_r2_", i)]] %||% ""),
            input_path = ""
          )
        } else {
          list(
            name = nm,
            input_r1 = "",
            input_r2 = "",
            input_path = trimws(input[[paste0("smp_path_", i)]] %||% "")
          )
        }
      })
    })

    # Collect sample_map from current barcode rows
    get_sample_map <- reactive({
      n <- n_barcodes()
      if (n == 0L) return(NULL)
      m <- list()
      for (i in seq_len(n)) {
        nm <- trimws(input[[paste0("bc_name_", i)]] %||% "")
        if (nchar(nm) > 0) m[[sprintf("barcode%02d", i)]] <- nm
      }
      if (length(m) == 0L) NULL else m
    })

    # --- Additional output directory ---
    # Text field: sync to shared whenever the user types or drag-drops a path
    observeEvent(input$extra_output_dir, {
      val <- trimws(input$extra_output_dir %||% "")
      shared$additional_output_dir <- if (nchar(val) > 0) val else NULL
    }, ignoreInit = TRUE)

    output$quality_threshold_display <- renderText({ as.character(input$quality_threshold) })
    output$min_read_length_display <- renderText({ as.character(input$min_read_length) })

    output$summary_pipeline <- renderText({
      switch(input$pipeline,
        "sr_amp" = "16S rRNA Sequencing",
        "sr_meta" = "Metagenomics (WGS)",
        input$pipeline
      )
    })

    output$summary_technology <- renderText({
      switch(input$technology,
        "illumina" = "Illumina",
        "iontorrent" = "Ion Torrent",
        "bgi" = "BGI Platforms",
        input$technology
      )
    })

    output$summary_sample_type <- renderText({
      tools::toTitleCase(input$sample_type)
    })

    output$summary_run_scope <- renderText({
      switch(input$run_scope,
        "full" = "Full Pipeline",
        "qc" = "QC Only",
        "analysis" = "Analysis Only",
        input$run_scope
      )
    })

    validate_inputs <- reactive({
      errors <- character(0)

      if (input$paired_end) {
        if (nchar(input$input_r1) == 0) errors <- c(errors, "Forward reads (R1) path is required")
        if (nchar(input$input_r2) == 0) errors <- c(errors, "Reverse reads (R2) path is required")
      } else {
        if (nchar(input$input_path) == 0) errors <- c(errors, "Input path is required")
      }

      if (n_samples() > 0) {
        s1_name <- trimws(input$sample1_name %||% "")
        if (nchar(s1_name) == 0) {
          errors <- c(errors, "Sample 1 name is required once additional samples are added")
        }

        names_seen <- if (nchar(s1_name) > 0) s1_name else character(0)
        extras <- get_extra_samples()
        for (i in seq_along(extras)) {
          s <- extras[[i]]
          label <- sprintf("Sample %d", i + 1L)
          if (nchar(s$name) == 0) {
            errors <- c(errors, sprintf("%s name is required", label))
          } else if (s$name %in% names_seen) {
            errors <- c(errors, sprintf("%s name '%s' is already used — sample names must be unique", label, s$name))
          } else {
            names_seen <- c(names_seen, s$name)
          }
          if (input$paired_end) {
            if (nchar(s$input_r1) == 0) errors <- c(errors, sprintf("%s: Forward reads (R1) path is required", label))
            if (nchar(s$input_r2) == 0) errors <- c(errors, sprintf("%s: Reverse reads (R2) path is required", label))
          } else {
            if (nchar(s$input_path) == 0) errors <- c(errors, sprintf("%s: Input path is required", label))
          }
        }
      }

      if (input$pipeline == "sr_meta" && nchar(input$kraken_db) == 0) {
        errors <- c(errors, "Kraken2 database path is required for metagenomics")
      }

      if (input$pipeline == "sr_amp") {
        if (is.na(input$dada2_trunc_f) || input$dada2_trunc_f < 50) {
          errors <- c(errors, "DADA2 forward truncation length must be at least 50")
        }
        if (is.na(input$dada2_trunc_r) || input$dada2_trunc_r < 50) {
          errors <- c(errors, "DADA2 reverse truncation length must be at least 50")
        }
      }

      list(valid = length(errors) == 0, errors = errors)
    })

    output$validation_messages <- renderUI({
      val <- validate_inputs()

      if (val$valid) {
        div(
          class = "alert alert-success",
          role = "alert",
          style = "font-size: 0.875rem;",
          icon("check-circle"), " Configuration is valid"
        )
      } else {
        div(
          class = "alert alert-danger",
          role = "alert",
          style = "font-size: 0.875rem;",
          icon("triangle-exclamation"), " ", tags$b("Issues:"),
          tags$ul(
            class = "mb-0 mt-2",
            lapply(val$errors, function(e) tags$li(e))
          )
        )
      }
    })

    build_command <- reactive({
      cmd <- c(
        file.path(dirname(getwd()), "stamina-biome"),
        "run",
        "-p", input$pipeline
      )

      if (input$paired_end) {
        cmd <- c(cmd, "-i", sprintf("%s,%s", input$input_r1, input$input_r2))
      } else {
        cmd <- c(cmd, "-i", input$input_path)
      }

      cmd <- c(cmd, "-o", file.path(dirname(getwd()), "outputs"))

      if (nchar(input$run_name) > 0) {
        cmd <- c(cmd, "--run-name", input$run_name)
      }

      cmd <- c(cmd, "--sample-type", input$sample_type)

      if (input$manually_allocate_threads) {
        cmd <- c(cmd, "--threads", as.character(input$threads))
      }

      if (input$pipeline == "sr_amp") {
        cmd <- c(cmd, "--dada2-trunc-f", as.character(input$dada2_trunc_f))
        cmd <- c(cmd, "--dada2-trunc-r", as.character(input$dada2_trunc_r))
      } else if (input$pipeline == "sr_meta") {
        if (nchar(input$kraken_db) > 0) {
          cmd <- c(cmd, "--db", input$kraken_db)
        }
        if (input$human_depletion) {
          cmd <- c(cmd, "--human-depletion")
        }
      }

      cmd <- c(cmd, "--quality-threshold", as.character(input$quality_threshold))
      cmd <- c(cmd, "--min-length", as.character(input$min_read_length))

      cmd
    })

    observeEvent(input$dry_run, {
      cmd <- build_command()

      showModal(modalDialog(
        title = "Preview: Pipeline Command",
        tags$p("The following command will be executed:"),
        tags$pre(
          style = "background: #f3f4f6; padding: 1rem; border-radius: 0.375rem; overflow-x: auto;",
          paste(cmd, collapse = " \\\n  ")
        ),
        footer = modalButton("Close"),
        size = "l"
      ))
    })

    observeEvent(input$run_pipeline, {
      cat("[DEBUG] Run Pipeline button clicked\n")

      val <- validate_inputs()

      if (!val$valid) {
        cat("[DEBUG] Validation failed:", paste(val$errors, collapse = ", "), "\n")
        showNotification(
          paste("Validation errors:", paste(val$errors, collapse = "; ")),
          type = "error",
          duration = 10
        )
        return()
      }

      cat("[DEBUG] Validation passed\n")

      # Capture this module's own output-dir field fresh, right as the run starts.
      # shared$additional_output_dir is a single global value also written to by the
      # LR module's own field-change observer — without re-asserting it here at
      # run-time, visiting the other tab (even with its field empty) can silently
      # clobber whatever this module's field held.
      extra_output_dir_val <- trimws(input$extra_output_dir %||% "")
      shared$additional_output_dir <- if (nchar(extra_output_dir_val) > 0) extra_output_dir_val else NULL
      cat("[DEBUG] shared$additional_output_dir (sr_meta run):", if (is.null(shared$additional_output_dir)) "(none)" else shared$additional_output_dir, "\n")

      run_id <- if (!is.null(input$run_name) && nchar(trimws(input$run_name)) > 0) {
        sanitized <- trimws(input$run_name)
        sanitized <- gsub("[\\/:*?\"<>|\\\\]", "_", sanitized)
        sanitized <- gsub("\\s+", "_", sanitized)
        sanitized
      } else {
        format(Sys.time(), "%Y%m%d_%H%M%S")
      }

      threads_value <- if (input$manually_allocate_threads) {
        input$threads
      } else {
        4
      }

      output_selected <- c()
      if (input$output_raw_csv) output_selected <- c(output_selected, "raw_csv")
      if (input$output_pie_chart) output_selected <- c(output_selected, "pie_chart")
      if (input$output_heatmap) output_selected <- c(output_selected, "heatmap")
      if (input$output_stacked_bar) output_selected <- c(output_selected, "stacked_bar")
      if (input$output_quality_reports) output_selected <- c(output_selected, "quality_reports")
      if (length(output_selected) == 0) output_selected <- c("all")

      base_params <- list(
        pipeline = input$pipeline,
        technology = input$technology,
        sample_type = input$sample_type,
        paired_end = input$paired_end,
        quality_threshold = input$quality_threshold,
        min_read_length = input$min_read_length,
        threads = threads_value,
        dada2_trunc_f = input$dada2_trunc_f,
        dada2_trunc_r = input$dada2_trunc_r,
        kraken_db             = input$kraken_db,
        kraken_confidence     = input$kraken_confidence,
        kraken_min_hit_groups = input$kraken_min_hit_groups,
        kraken_memory_mapping = input$kraken_memory_mapping,
        human_depletion       = input$human_depletion,
        bracken_readlen       = shared$bracken_readlen %||% "auto",
        trim_adapter = input$trim_adapter,
        demultiplex = input$demultiplex,
        primer_sequences = input$primer_sequences,
        barcode_sequences = input$barcode_sequences,
        barcoding_kit = input$barcoding_kit,
        external_db_dir = input$external_db_dir,
        database_type = input$database_type,
        run_scope = input$run_scope,
        valencia = input$valencia,
        output_selected = output_selected,
        enable_postprocess = any(c(isTRUE(input$output_raw_csv), isTRUE(input$output_pie_chart),
                                   isTRUE(input$output_heatmap), isTRUE(input$output_stacked_bar),
                                   isTRUE(input$output_quality_reports))),
        sample_map        = get_sample_map()
      )

      generate_fn <- if (input$pipeline == "sr_amp") generate_sr_amp_config else generate_sr_meta_config

      show_missing_deps_modal <- function(dep_validation) {
        showModal(modalDialog(
          title = "Missing Dependencies",
          tags$div(
            class = "alert alert-danger",
            icon("triangle-exclamation"), " ", tags$b("Cannot start pipeline"),
            tags$ul(
              class = "mt-2 mb-0",
              lapply(dep_validation$errors, function(e) tags$li(e))
            )
          ),
          footer = tagList(
            actionButton("goto_setup_from_error", "Go to Setup Wizard", class = "btn-primary"),
            modalButton("Cancel")
          ),
          easyClose = FALSE
        ))

        observeEvent(input$goto_setup_from_error, {
          removeModal()
          shared$goto_page <- "Setup Wizard"
        }, once = TRUE)
      }

      extras <- get_extra_samples()

      if (length(extras) == 0L) {
        # ---- Single-sample path (unchanged behavior) ----
        params <- c(base_params, list(
          run_id = run_id,
          input_path = input$input_path,
          input_r1 = input$input_r1,
          input_r2 = input$input_r2,
          output_dir = file.path(dirname(getwd()), "outputs")
        ))

        config <- generate_fn(params)
        dep_validation <- validate_dependencies(config)

        if (!dep_validation$valid) {
          show_missing_deps_modal(dep_validation)
          return()
        }
        if (length(dep_validation$warnings) > 0) {
          showNotification(paste(dep_validation$warnings, collapse = "\n"), type = "warning", duration = 10)
        }

        config_file <- save_config(config, run_id)

        shared$current_batch <- NULL
        shared$current_run <- list(
          run_id = run_id,
          pipeline = input$pipeline,
          config_file = config_file,
          run_name = input$run_name,
          sample_type = input$sample_type
        )

        cat("[DEBUG] Config saved to:", config_file, "\n")
        cat("[DEBUG] Setting run_status to ready (will trigger modal)\n")
        shared$run_status <- "ready"
        return()
      }

      # ---- Batch path (2+ samples): run_name/run_id becomes the batch ID ----
      sanitize_sample <- function(x) {
        s <- gsub("[\\/:*?\"<>|\\\\]", "_", trimws(x))
        s <- gsub("\\s+", "_", s)
        if (nchar(s) == 0) "sample" else s
      }

      batch_id <- run_id
      batch_output_dir <- file.path(dirname(getwd()), "outputs", batch_id)

      all_samples <- c(
        list(list(
          name = trimws(input$sample1_name %||% "Sample1"),
          input_r1 = input$input_r1, input_r2 = input$input_r2, input_path = input$input_path
        )),
        extras
      )

      batch_runs <- list()
      dep_error <- NULL

      for (i in seq_along(all_samples)) {
        smp <- all_samples[[i]]
        sample_run_id <- sanitize_sample(smp$name)

        params <- c(base_params, list(
          run_id = sample_run_id,
          input_path = smp$input_path,
          input_r1 = smp$input_r1,
          input_r2 = smp$input_r2,
          output_dir = batch_output_dir
        ))

        config <- generate_fn(params)

        if (i == 1L) {
          dep_validation <- validate_dependencies(config)
          if (!dep_validation$valid) {
            dep_error <- dep_validation
            break
          }
          if (length(dep_validation$warnings) > 0) {
            showNotification(paste(dep_validation$warnings, collapse = "\n"), type = "warning", duration = 10)
          }
        }

        # Filename disambiguator only (config$run$run_id stays the plain sample id) —
        # avoids collisions between same-named samples across different batches, since
        # save_config() writes into a flat outputs/config_<id>.json namespace.
        config_file <- save_config(config, paste0(batch_id, "__", sample_run_id))

        batch_runs[[i]] <- list(
          run_id = sample_run_id,
          pipeline = input$pipeline,
          config_file = config_file,
          sample_name = smp$name
        )
      }

      if (!is.null(dep_error)) {
        show_missing_deps_modal(dep_error)
        return()
      }

      cat("[DEBUG] Batch config saved for", length(batch_runs), "sample(s), batch_id:", batch_id, "\n")
      cat("[DEBUG] Setting run_status to ready (will trigger batch queue)\n")

      shared$current_run <- NULL
      shared$current_batch <- list(
        batch_id = batch_id,
        pipeline = input$pipeline,
        runs = batch_runs
      )
      shared$run_status <- "ready"
    })
  })
}
