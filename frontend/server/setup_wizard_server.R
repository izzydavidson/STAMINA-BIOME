# ---------------------------------------------------------------------------
# setup_wizard_server.R
# Shiny module server for the setup wizard overlay.
# Calls wizard_defs.R functions for detection; launches downloads via
# processx background subprocess for real-time log streaming.
# Does NOT modify main/ or cli/.
#
# Selection mechanism: pure JS CSS-class toggling via data-wiz-id attributes.
# No Shiny checkbox inputs — avoids double-toggle and re-render reset bugs.
# JS sends count to input$wiz_n_sel; install button triggers JS collection of
# selected IDs which are passed to input$pending_install as a comma-separated
# string, triggering the actual download.
# ---------------------------------------------------------------------------

setup_wizard_server <- function(id, shared) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    repo_root    <- wizard_repo_root()
    defs_path    <- normalizePath(file.path(getwd(), "utils", "wizard_defs.R"))
    marker_path  <- wizard_marker_file(repo_root)

    # -----------------------------------------------------------------------
    # Reactive state
    # -----------------------------------------------------------------------
    wiz_installed  <- reactiveVal(wizard_detect_installed(repo_root))
    docker_ok      <- reactiveVal(NA)          # NA = not yet checked

    # -----------------------------------------------------------------------
    # Bracken readlen preference — load saved value on init, persist on change
    # -----------------------------------------------------------------------
    local({
      val <- wizard_load_bracken_readlen(repo_root)
      shared$bracken_readlen <- val
      session$onFlushed(function() {
        updateSelectInput(session, "bracken_readlen", selected = val)
      }, once = TRUE)
    })

    observeEvent(input$bracken_readlen, {
      wizard_save_bracken_readlen(input$bracken_readlen, repo_root)
      shared$bracken_readlen <- input$bracken_readlen
    }, ignoreInit = TRUE)

    dl_proc        <- reactiveVal(NULL)        # processx process
    dl_running     <- reactiveVal(FALSE)
    dl_log_lines   <- reactiveVal(character(0))
    dl_prog_pct    <- reactiveVal(0L)
    dl_prog_text   <- reactiveVal("Waiting...")
    dl_done        <- reactiveVal(FALSE)       # TRUE once proc exits

    # -----------------------------------------------------------------------
    # Docker check — auto on first render
    # -----------------------------------------------------------------------
    observe({
      docker_ok(wizard_check_docker())
    })

    output$docker_status_ui <- renderUI({
      ok <- docker_ok()
      if (is.na(ok)) {
        div(class = "wiz-docker-row",
            div(class = "wiz-docker-icon wiz-dok-chk", "..."),
            span(style = "color:#64748b; font-size:.875rem;", "Checking Docker..."),
            actionButton(ns("recheck_docker"), "Recheck",
                         class = "btn btn-sm btn-outline-secondary ms-auto"))
      } else if (ok) {
        div(class = "wiz-docker-row",
            div(class = "wiz-docker-icon wiz-dok-ok", "\u2713"),
            span(style = "color:#1e293b; font-size:.875rem; font-weight:500;",
                 "Docker is installed and running"),
            actionButton(ns("recheck_docker"), "Recheck",
                         class = "btn btn-sm btn-outline-secondary ms-auto"))
      } else {
        div(class = "wiz-docker-row",
            div(class = "wiz-docker-icon wiz-dok-err", "\u2717"),
            div(
              span(style = "color:#dc2626; font-weight:600; font-size:.875rem;",
                   "Docker is not running or not installed."),
              tags$br(),
              tags$small(style = "color:#64748b;",
                         "Install Docker Desktop from ",
                         tags$a(href  = "https://www.docker.com/products/docker-desktop/",
                                target = "_blank", "docker.com"),
                         ", then click Recheck.")
            ),
            actionButton(ns("recheck_docker"), "Recheck",
                         class = "btn btn-sm btn-outline-secondary ms-auto"))
      }
    })

    observeEvent(input$recheck_docker, {
      docker_ok(wizard_check_docker())
    })

    # -----------------------------------------------------------------------
    # Build a single item card
    # Uses data-wiz-id attribute for pure JS class-based selection.
    # No Shiny inputs inside the card — avoids double-toggle / re-render bugs.
    # -----------------------------------------------------------------------
    make_item_card <- function(item_id, name, desc, meta, is_installed) {
      cls <- if (is_installed) "wiz-item wiz-installed" else "wiz-item"
      div(class = cls,
          `data-wiz-id` = item_id,
          div(class = "wiz-item-body",
              div(class = "wiz-item-name", name),
              div(class = "wiz-item-desc", desc),
              div(class = "wiz-item-meta", meta)),
          if (is_installed)
            div(class = "wiz-installed-badge", "\u2713 Installed")
          else
            NULL
      )
    }

    # -----------------------------------------------------------------------
    # Render database cards
    # -----------------------------------------------------------------------
    output$databases_ui <- renderUI({
      inst <- wiz_installed()
      tagList(lapply(seq_along(WIZARD_DATABASES), function(i) {
        db        <- WIZARD_DATABASES[[i]]
        inst_flag <- db$id %in% inst$databases
        make_item_card(
          item_id      = db$id,
          name         = db$name,
          desc         = db$desc,
          meta         = sprintf("Size: ~%s GB | Pipelines: %s", db$size, db$pipelines),
          is_installed = inst_flag
        )
      }))
    })

    # -----------------------------------------------------------------------
    # Render tool cards (VALENCIA + Dorado binaries)
    # -----------------------------------------------------------------------
    output$tools_ui <- renderUI({
      inst <- wiz_installed()
      tagList(
        # VALENCIA and other analysis tools
        lapply(seq_along(WIZARD_TOOLS), function(i) {
          tool      <- WIZARD_TOOLS[[i]]
          inst_flag <- tool$id %in% inst$tools
          make_item_card(
            item_id      = tool$id,
            name         = tool$name,
            desc         = tool$desc,
            meta         = sprintf("Size: %s | For: %s samples", tool$size, tool$samples),
            is_installed = inst_flag
          )
        }),
        # Dorado basecalling binaries
        lapply(seq_along(WIZARD_DORADO_BINARIES), function(i) {
          b         <- WIZARD_DORADO_BINARIES[[i]]
          inst_flag <- b$id %in% inst$tools
          make_item_card(
            item_id      = b$id,
            name         = b$name,
            desc         = b$desc,
            meta         = sprintf("Size: %s | Required for Dorado basecalling", b$size),
            is_installed = inst_flag
          )
        }),
        # Reference genome indexes (minimap2)
        lapply(seq_along(WIZARD_REFERENCE_INDEXES), function(i) {
          idx       <- WIZARD_REFERENCE_INDEXES[[i]]
          inst_flag <- idx$id %in% inst$tools
          make_item_card(
            item_id      = idx$id,
            name         = idx$name,
            desc         = idx$desc,
            meta         = sprintf("Size: %s | %s", idx$size, idx$requires),
            is_installed = inst_flag
          )
        })
      )
    })

    # -----------------------------------------------------------------------
    # Render model cards
    # -----------------------------------------------------------------------
    output$models_ui <- renderUI({
      inst <- wiz_installed()
      tagList(lapply(seq_along(WIZARD_DORADO_MODELS), function(i) {
        model     <- WIZARD_DORADO_MODELS[[i]]
        inst_flag <- model$id %in% inst$models
        make_item_card(
          item_id      = model$id,
          name         = model$name,
          desc         = model$desc,
          meta         = sprintf("Size: %s", model$size),
          is_installed = inst_flag
        )
      }))
    })

    # -----------------------------------------------------------------------
    # Selection count badge — driven by JS via input$wiz_n_sel
    # JS sets this via Shiny.setInputValue('setup_wizard-wiz_n_sel', count)
    # -----------------------------------------------------------------------
    sel_count <- reactive({
      n <- input$wiz_n_sel
      if (is.null(n)) 0L else as.integer(n)
    })

    output$sel_count_ui <- renderUI({
      n <- sel_count()
      if (n == 0)
        span(class = "wiz-sel-count", "Nothing selected")
      else
        span(class = "wiz-sel-count",
             tags$b(n), if (n == 1) " item selected" else " items selected")
    })

    # -----------------------------------------------------------------------
    # Progress / log UI (bound to reactive values updated by polling observer)
    # -----------------------------------------------------------------------
    output$prog_label <- renderText({
      dl_prog_text()
    })

    output$install_log_ui <- renderUI({
      lines <- dl_log_lines()
      tagList(lapply(lines, function(ln) {
        cls <- if (grepl("^\\[OK\\]",  ln))  "wiz-ll wiz-ll-ok"
               else if (grepl("^\\[ERR\\]", ln)) "wiz-ll wiz-ll-err"
               else if (grepl("^>>>",       ln))  "wiz-ll wiz-ll-hdr"
               else                               "wiz-ll"
        # Strip prefix for display
        txt <- sub("^\\[(OK|ERR|LOG|PROG:[0-9]+)\\] ?", "", ln)
        div(class = cls, txt)
      }))
    })

    # -----------------------------------------------------------------------
    # Polling observer — reads subprocess stdout every 400 ms
    # -----------------------------------------------------------------------
    observe({
      req(dl_running())
      invalidateLater(400, session)

      proc <- dl_proc()
      if (is.null(proc)) return()

      new_lines <- character(0)
      if (proc$is_alive()) {
        new_lines <- tryCatch(proc$read_output_lines(), error = function(e) character(0))
      } else {
        # Drain remaining output
        new_lines <- tryCatch(proc$read_output_lines(), error = function(e) character(0))
        dl_running(FALSE)

        exit_code <- tryCatch(proc$get_exit_status(), error = function(e) -1L)
        all_lines <- c(dl_log_lines(), new_lines)
        done_line <- grep("^\\[DONE:", all_lines, value = TRUE)

        # Primary check: [DONE:ok] in output. Fallback: exit code 0 (from quit(status=0))
        # if the output was flushed before we could read it (rare pipe timing issue).
        is_success <- (length(done_line) > 0 &&
                       grepl("\\[DONE:ok\\]", done_line[length(done_line)])) ||
                      (length(done_line) == 0 && exit_code == 0L)

        if (is_success) {
          wizard_mark_complete(repo_root)
          shared$setup_complete <- TRUE
          dl_log_lines(c(all_lines,
                         "[OK] Setup complete — you can now run pipelines",
                         "[LOG] Returning to dashboard in a moment..."))
          dl_prog_pct(100L)
          dl_prog_text("Setup complete!")
          runjs(sprintf("document.getElementById('%s').style.width='100%%';", ns("wiz-prog-fill")))
          # Refresh install state
          wiz_installed(wizard_detect_installed(repo_root))
          shinyjs::enable("skip_wizard")
          # Auto-close after 2 s
          shinyjs::delay(2000, shinyjs::hide("setup-wizard-overlay", asis = TRUE))
        } else {
          # Partial failure — show log, leave wizard open
          dl_log_lines(c(all_lines,
                         "[ERR] Some items failed. Check the log above, then retry or skip."))
          dl_prog_text("Installation incomplete — see errors above")
          shinyjs::enable("start_install")
          shinyjs::enable("skip_wizard")
          wiz_installed(wizard_detect_installed(repo_root))
        }
        dl_proc(NULL)
        return()
      }

      if (length(new_lines) == 0) return()

      # Parse PROG lines to update the progress bar
      prog_lines <- grep("^\\[PROG:", new_lines, value = TRUE)
      if (length(prog_lines) > 0) {
        last_prog <- prog_lines[length(prog_lines)]
        pct_match <- regmatches(last_prog, regexpr("(?<=\\[PROG:)\\d+", last_prog, perl = TRUE))
        if (length(pct_match) > 0) {
          pct <- as.integer(pct_match)
          dl_prog_pct(pct)
          runjs(sprintf("document.getElementById('%s').style.width='%d%%';",
                        ns("wiz-prog-fill"), pct))
          # Extract text after the '] ' separator
          prog_text <- sub("^\\[PROG:\\d+\\] ?", "", last_prog)
          dl_prog_text(prog_text)
        }
      }

      # Filter out raw PROG/DONE lines from display log; keep LOG/OK/ERR/>>>
      display_lines <- new_lines[!grepl("^\\[PROG:|^\\[DONE:", new_lines)]
      if (length(display_lines) > 0) {
        dl_log_lines(c(dl_log_lines(), display_lines))
        # Auto-scroll the log box via JS
        runjs(sprintf(
          "(function(){var b=document.getElementById('%s');if(b)b.scrollTop=b.scrollHeight;})();",
          ns("wiz-log-box")
        ))
      }
    })

    # -----------------------------------------------------------------------
    # "Download & Install Selected" button
    # Uses JS to collect .wiz-selected item IDs from the DOM, then sets
    # input$pending_install to trigger the actual install observer.
    # -----------------------------------------------------------------------
    observeEvent(input$start_install, {
      runjs(sprintf("
        (function() {
          var ids = [];
          document.querySelectorAll('.wiz-item.wiz-selected[data-wiz-id]').forEach(function(el) {
            ids.push(el.getAttribute('data-wiz-id'));
          });
          Shiny.setInputValue('%s',
            ids.length > 0 ? ids.join(',') : '__empty__',
            {priority: 'event'});
        })();
      ", ns("pending_install")))
    })

    # -----------------------------------------------------------------------
    # Actual install work — triggered by input$pending_install
    # -----------------------------------------------------------------------
    observeEvent(input$pending_install, {
      id_str <- input$pending_install
      if (is.null(id_str) || id_str == "__empty__" || nchar(trimws(id_str)) == 0) {
        showNotification(
          "No items selected. Click cards to select them, then click Download.",
          type = "warning", duration = 4)
        return()
      }

      all_ids <- trimws(strsplit(id_str, ",")[[1]])
      all_ids <- all_ids[nchar(all_ids) > 0]

      inst <- isolate(wiz_installed())

      # Categorise IDs into databases / tools / models
      db_ids    <- vapply(WIZARD_DATABASES,         function(x) x$id, "")
      tool_ids  <- c(vapply(WIZARD_TOOLS,            function(x) x$id, ""),
                     vapply(WIZARD_DORADO_BINARIES,  function(x) x$id, ""),
                     vapply(WIZARD_REFERENCE_INDEXES, function(x) x$id, ""))
      model_ids <- vapply(WIZARD_DORADO_MODELS,     function(x) x$id, "")

      sel_db_ids    <- all_ids[all_ids %in% db_ids    & !(all_ids %in% inst$databases)]
      sel_tool_ids  <- all_ids[all_ids %in% tool_ids  & !(all_ids %in% inst$tools)]
      sel_model_ids <- all_ids[all_ids %in% model_ids & !(all_ids %in% inst$models)]

      total <- length(sel_db_ids) + length(sel_tool_ids) + length(sel_model_ids)
      if (total == 0) {
        showNotification("All selected items are already installed.",
                         type = "warning", duration = 4)
        return()
      }

      # Build helper to quote an R character vector for injection into script
      r_vec <- function(ids) {
        if (length(ids) == 0) return("character(0)")
        paste0("c(", paste(sprintf('"%s"', ids), collapse = ", "), ")")
      }

      # Write an Rscript that sources wizard_defs.R and calls wizard_run_downloads
      script_body <- sprintf(
'source("%s")
wizard_run_downloads(
  selected_db_ids    = %s,
  selected_tool_ids  = %s,
  selected_model_ids = %s,
  repo_root          = "%s"
)',
        gsub("\\\\", "/", defs_path),
        r_vec(sel_db_ids),
        r_vec(sel_tool_ids),
        r_vec(sel_model_ids),
        gsub("\\\\", "/", repo_root)
      )

      tmp_script <- tempfile(pattern = "wiz_dl_", fileext = ".R")
      writeLines(script_body, tmp_script)

      # Reset log state
      dl_log_lines(character(0))
      dl_prog_pct(0L)
      dl_prog_text(sprintf("Starting installation of %d item(s)...", total))
      dl_done(FALSE)

      # Show progress panel, disable buttons while running
      shinyjs::show("wiz-prog-wrap")
      shinyjs::disable("start_install")
      shinyjs::disable("skip_wizard")

      # Launch background Rscript
      proc <- tryCatch(
        processx::process$new(
          command = "Rscript",
          args    = c("--vanilla", tmp_script),
          stdout  = "|",
          stderr  = "2>&1"
        ),
        error = function(e) {
          showNotification(paste("Failed to start installer:", e$message), type = "error")
          shinyjs::enable("start_install")
          shinyjs::enable("skip_wizard")
          NULL
        }
      )

      if (!is.null(proc)) {
        dl_proc(proc)
        dl_running(TRUE)
      }
    })

    # -----------------------------------------------------------------------
    # "Skip for Now" button
    # -----------------------------------------------------------------------
    observeEvent(input$skip_wizard, {
      wizard_mark_complete(repo_root)
      shared$setup_complete <- TRUE
      shinyjs::hide("setup-wizard-overlay", asis = TRUE)
    })

    # -----------------------------------------------------------------------
    # React to "Return to Wizard" signal from dashboard
    # -----------------------------------------------------------------------
    observeEvent(shared$show_wizard, {
      if (isTRUE(shared$show_wizard)) {
        # Refresh install state before showing
        wiz_installed(wizard_detect_installed(repo_root))
        docker_ok(wizard_check_docker())
        # Show wizard overlay with flex display
        shinyjs::show("setup-wizard-overlay", asis = TRUE, anim = TRUE, animType = "fade")
        # Force correct display type via JS (shinyjs::show sets display:block by default)
        shinyjs::runjs("
          var elem = document.getElementById('setup-wizard-overlay');
          if (elem) elem.style.display = 'flex';
        ")
        shared$show_wizard <- FALSE
      }
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  })
}
