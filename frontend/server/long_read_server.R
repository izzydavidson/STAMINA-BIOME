# Kit barcode count lookup — caps the "+ Add barcode" button
KIT_BARCODE_COUNTS <- list(
  "EXP-PBC001"    = 12L, "EXP-PBC096"    = 96L,
  "EXP-NBD104"    = 24L, "EXP-NBD196"    = 96L,
  "SQK-RBK004"    = 12L, "SQK-RBK110"    = 96L,
  "SQK-16S024"    = 24L, "SQK-NBD114-24" = 24L,
  "SQK-NBD114-96" = 96L, "SQK-RPB114-24" = 24L
)

# Barcoding kits Dorado accepts for --kit-name (Dorado 1.x). A ligation/sequencing kit
# such as SQK-LSK114 is not one: it belongs in the Ligation Kit field.
DORADO_BARCODE_KITS <- c(
  "EXP-NBD103", "EXP-NBD104", "EXP-NBD114", "EXP-NBD114-24", "EXP-NBD196", "EXP-PBC001",
  "EXP-PBC096", "SQK-16S024", "SQK-16S114-24", "SQK-DRB004-24", "SQK-HTB114-96", "SQK-LWB001",
  "SQK-MAB114-24", "SQK-MLK111-96-XL", "SQK-MLK114-96-XL", "SQK-NBD111-24", "SQK-NBD111-96", "SQK-NBD114-24",
  "SQK-NBD114-96", "SQK-PBK004", "SQK-PCB109", "SQK-PCB110", "SQK-PCB111-24", "SQK-PCB114-24",
  "SQK-RAB201", "SQK-RAB204", "SQK-RBK001", "SQK-RBK004", "SQK-RBK110-96", "SQK-RBK111-24",
  "SQK-RBK111-96", "SQK-RBK114-24", "SQK-RBK114-96", "SQK-RLB001", "SQK-RPB004", "SQK-RPB114-24",
  "TWIST-16-UDI", "TWIST-96A-UDI", "VSK-PTC001", "VSK-VMK001", "VSK-VMK004", "VSK-VPS001"
)

# kit_field_check(barcoding_kit, ligation_kit) -> list(errors, warnings)
# A Barcoding Kit that Dorado does not know (often the two kit fields swapped) is an
# error, so the run fails here at once instead of after the FAST5 conversion.
kit_field_check <- function(bk, lk) {
  bk <- toupper(trimws(bk %||% "")); lk <- toupper(trimws(lk %||% ""))
  out <- list(errors = character(0), warnings = character(0))
  if (!nzchar(bk) || bk %in% DORADO_BARCODE_KITS) return(out)
  out$errors <- if (lk %in% DORADO_BARCODE_KITS) {
    sprintf("Barcoding Kit and Ligation Kit are swapped: %s is a barcoding kit and %s is a ligation/sequencing kit. Put %s in Barcoding Kit and %s in Ligation Kit.",
            lk, bk, lk, bk)
  } else {
    sprintf("Barcoding Kit %s is not a Dorado barcoding kit (for example EXP-PBC001, SQK-RBK114-24, SQK-NBD114-96). Ligation/sequencing kits such as SQK-LSK114 go in the Ligation Kit field.",
            bk)
  }
  out
}

# Site-specific Kraken2 defaults (also used per sample type in mixed runs)
SITE_KRAKEN_DEFAULTS <- list(
  vaginal = list(conf = 0.02, mhg = 2L),
  gut     = list(conf = 0.03, mhg = 4L),
  oral    = list(conf = 0.04, mhg = 4L),
  skin    = list(conf = 0.03, mhg = 4L),
  other   = list(conf = 0.05, mhg = 2L)
)
SITE_CHOICES <- c("Vaginal" = "vaginal", "Gut" = "gut", "Oral" = "oral", "Skin" = "skin", "Other" = "other")

# NULL -> empty list (the app-wide %||% calls is.na(), which errors on longer lists)
or_empty <- function(x) if (is.null(x)) list() else x

# TRUE when <path> is a built Kraken2 database (has its hash.k2d index)
is_kraken2_db <- function(path) {
  nzchar(path) && dir.exists(path) && file.exists(file.path(path, "hash.k2d"))
}

# Output Directory field -> absolute folder the finished run is moved to ("" when unset).
# "~" and paths relative to the home folder (e.g. "Desktop") are accepted.
resolve_final_dir <- function(x) {
  x <- trimws(x %||% "")
  if (!nzchar(x)) return("")
  x <- path.expand(x)
  if (!startsWith(x, "/")) x <- file.path(Sys.getenv("HOME"), x)
  normalizePath(x, mustWork = FALSE)
}

# Validation error for the Output Directory field, or character(0)
final_dir_errors <- function(x) {
  d <- resolve_final_dir(x)
  if (nzchar(d) && !dir.exists(d)) sprintf("Output Directory not found: %s", d) else character(0)
}

# Kraken2 runs with --memory-mapping, so it reads the database from disk for every
# sample. A large database on an external drive (USB) can take hours per sample.
SLOW_DB_MIN_GB <- 20

# kraken_db_slow_warnings(c("Comparison database" = path, ...)) -> warning messages
# for databases of SLOW_DB_MIN_GB or more under /Volumes (external drives on macOS)
kraken_db_slow_warnings <- function(paths) {
  warnings <- character(0)
  for (label in names(paths)) {
    p <- trimws(paths[[label]] %||% "")
    if (!nzchar(p)) next
    real <- normalizePath(p, mustWork = FALSE)
    if (!startsWith(real, "/Volumes/")) next
    gb <- suppressWarnings(file.size(file.path(real, "hash.k2d"))) / 1e9
    if (is.na(gb) || gb < SLOW_DB_MIN_GB) next
    warnings <- c(warnings, sprintf(
      "%s is %.0f GB and on an external drive (%s). Kraken2 reads it from the drive for every sample, which can take hours per sample. Copy it to the internal drive, or choose a smaller database.",
      label, gb, p))
  }
  warnings
}

# Every Kraken2 database a metagenomics run would use, labelled for messages
kraken_db_paths <- function(kraken_db, site_dbs, comparison_db) {
  paths <- list()
  if (nzchar(trimws(kraken_db %||% ""))) paths[["Kraken2 Database Path"]] <- kraken_db
  for (site in names(site_dbs)) {
    label <- names(SITE_CHOICES)[SITE_CHOICES == site]
    paths[[sprintf("%s Kraken2 database", if (length(label)) label else site)]] <- site_dbs[[site]]
  }
  if (nzchar(trimws(comparison_db %||% ""))) paths[["Comparison database"]] <- comparison_db
  paths
}

# Yellow notice under the validation box (same Bootstrap alert as the other messages)
slow_db_alert <- function(warnings) {
  if (length(warnings) == 0) return(NULL)
  div(
    class = "alert alert-warning",
    role = "alert",
    style = "font-size: 0.875rem;",
    icon("triangle-exclamation"), " ", tags$b("Check:"),
    tags$ul(class = "mb-0 mt-2", lapply(warnings, function(w) tags$li(w)))
  )
}

# Mixed runs: errors for per-type / comparison / fallback DB paths that are not Kraken2 databases
mixed_db_errors <- function(site_dbs, comparison_db, fallback_db) {
  errors <- character(0)
  for (site in names(site_dbs)) {
    p <- site_dbs[[site]]
    label <- names(SITE_CHOICES)[SITE_CHOICES == site]
    if (!dir.exists(p)) {
      errors <- c(errors, sprintf("%s Kraken2 database not found: %s", label, p))
    } else if (!is_kraken2_db(p)) {
      errors <- c(errors, sprintf("%s Kraken2 database is not a built Kraken2 database (no hash.k2d): %s", label, p))
    }
  }
  if (nchar(comparison_db) > 0) {
    if (!dir.exists(comparison_db)) {
      errors <- c(errors, sprintf("Comparison database not found: %s", comparison_db))
    } else if (!is_kraken2_db(comparison_db)) {
      errors <- c(errors, sprintf("Comparison database is not a built Kraken2 database (no hash.k2d): %s", comparison_db))
    }
  }
  if (nchar(fallback_db) > 0 && !is_kraken2_db(fallback_db)) {
    errors <- c(errors, sprintf("Kraken2 Database Path is not a built Kraken2 database (no hash.k2d): %s - point it at one database folder, or leave it empty when every sample type has its own database", fallback_db))
  }
  errors
}

# Normalise a barcode ID so pinned IDs (BC01, barcode1) match pipeline sample IDs (barcode01)
normalize_barcode_id <- function(bc) {
  m <- regmatches(bc, regexec("^(?i)(barcode|bc)0*([0-9]+)$", bc, perl = TRUE))[[1]]
  if (length(m) == 3) sprintf("barcode%02d", as.integer(m[3])) else bc
}

get_kit_max <- function(kit) {
  for (k in names(KIT_BARCODE_COUNTS)) {
    if (grepl(k, kit, fixed = TRUE)) return(KIT_BARCODE_COUNTS[[k]])
  }
  96L  # safe default for unknown kits
}

long_read_server <- function(id, shared) {
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

    observeEvent(input$dorado_bin_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "dorado_bin", value = path)
    })

    observeEvent(input$dorado_models_dir_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "dorado_models_dir", value = path)
    })

    observeEvent(input$kraken_db_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "kraken_db", value = path)
    })

    # ── Site-specific Kraken2 defaults ───────────────────────────────────────────
    # Gut/skin: conf=0.03, MHG=4 | oral: conf=0.04, MHG=4 | vaginal: conf=0.02, MHG=2
    observeEvent(input$sample_type, {
      # Mixed runs use per-sample-type settings (site_db_rows) instead
      defaults <- SITE_KRAKEN_DEFAULTS[[input$sample_type]]
      if (is.null(defaults)) return()
      updateNumericInput(session, "kraken_confidence",     value = defaults$conf)
      updateNumericInput(session, "kraken_min_hit_groups", value = defaults$mhg)
    }, ignoreInit = FALSE)

    is_mixed <- reactive({ identical(input$sample_type, "mixed") })

    observeEvent(input$comparison_db_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "comparison_db", value = path)
    })

    # Browse buttons for the per-sample-type Kraken2 DB fields (mixed runs)
    lapply(unname(SITE_CHOICES), function(site) {
      observeEvent(input[[paste0("site_db_browse_", site)]], {
        path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
        if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, paste0("site_db_", site), value = path)
      })
    })

    observeEvent(input$external_db_dir_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "external_db_dir", value = path)
    })

    observeEvent(input$extra_output_dir_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose folder)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) {
        updateTextInput(session, "extra_output_dir", value = path)
        shared$additional_output_dir <- path
      }
    })

    # --- Detect installed Dorado models (uses same logic as wizard) ---
    detect_installed_models <- function() {
      repo_root <- dirname(getwd())
      models_dir <- file.path(repo_root, "tools", "models", "dorado")

      # Use exact same model list as wizard_defs.R WIZARD_DORADO_MODELS
      wizard_models <- list(
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.2.0", name = "HAC v5.2.0 (RECOMMENDED)", desc = "High accuracy for modern 5kHz ONT data"),
        list(id = "dna_r10.4.1_e8.2_400bps_sup@v5.2.0", name = "SUP v5.2.0", desc = "Super accuracy for 5kHz ONT data (slower)"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.0.0", name = "HAC v5.0.0", desc = "High accuracy stable release"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v4.3.0", name = "HAC v4.3.0", desc = "Legacy high accuracy model"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v4.2.0", name = "HAC v4.2.0", desc = "Legacy baseline model"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v3.5.2", name = "HAC v3.5.2 (Legacy 4kHz)", desc = "High accuracy for LEGACY 4kHz R10.4.1 E8.2 data")
      )

      installed <- character(0)
      if (dir.exists(models_dir)) {
        for (m in wizard_models) {
          if (dir.exists(file.path(models_dir, m$id))) {
            installed <- c(installed, m$id)
          }
        }
      }
      installed
    }

    # Build Dorado model choices matching wizard display
    # Uses exact same model list and indicators as wizard_defs.R WIZARD_DORADO_MODELS
    build_dorado_choices <- function() {
      installed <- detect_installed_models()
      checkmark <- "\u2713"  # ✓ unicode checkmark (matches wizard badge)

      # Model definitions matching wizard_defs.R WIZARD_DORADO_MODELS exactly
      wizard_models <- list(
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.2.0", name = "HAC v5.2.0 (RECOMMENDED)"),
        list(id = "dna_r10.4.1_e8.2_400bps_sup@v5.2.0", name = "SUP v5.2.0"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.0.0", name = "HAC v5.0.0"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v4.3.0", name = "HAC v4.3.0"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v4.2.0", name = "HAC v4.2.0"),
        list(id = "dna_r10.4.1_e8.2_400bps_hac@v3.5.2", name = "HAC v3.5.2 (Legacy 4kHz)")
      )

      # Build choices with ✓ checkmark for installed models (matches wizard)
      choices <- c("Auto-detect" = "")
      for (m in wizard_models) {
        label <- paste0(m$name, if (m$id %in% installed) paste0(" ", checkmark) else "")
        choices <- c(choices, setNames(m$id, label))
      }
      choices
    }

    # Update dorado_model choices when UI loads and periodically (to detect wizard installs)
    observe({
      # Re-check every time the tab is accessed or models might have changed
      invalidateLater(5000)  # Check every 5 seconds for newly installed models
      updateSelectInput(session, "dorado_model", choices = build_dorado_choices())
    })

    # --- Barcode mapping state ---
    n_barcodes <- reactiveVal(0L)

    # Reset rows when the kit changes
    observeEvent(input$barcoding_kit, {
      n_barcodes(0L)
    }, ignoreInit = TRUE)

    # Add a barcode row (capped by kit max)
    observeEvent(input$add_barcode_row, {
      cur     <- n_barcodes()
      max_bc  <- get_kit_max(input$barcoding_kit %||% "")
      if (cur < max_bc) n_barcodes(cur + 1L)
    })

    # Remove the last barcode row
    observeEvent(input$remove_barcode_row, {
      cur <- n_barcodes()
      if (cur > 0L) n_barcodes(cur - 1L)
    })

    # Render dynamic barcode rows (mixed runs add a per-sample type column)
    output$barcode_map_rows <- renderUI({
      n <- n_barcodes()
      mixed <- is_mixed()
      if (n == 0L) return(NULL)
      tagList(lapply(seq_len(n), function(i) {
        auto_id <- sprintf("barcode%02d", i)
        div(
          class = "row mb-2 align-items-center",
          div(
            class = if (mixed) "col-md-5" else "col-md-7",
            textInput(
              ns(paste0("bc_name_", i)), NULL,
              placeholder = sprintf("Sample name (e.g., Patient%03d)", i),
              value = isolate(input[[paste0("bc_name_", i)]] %||% "")
            )
          ),
          div(
            class = if (mixed) "col-md-4" else "col-md-5",
            textInput(
              ns(paste0("bc_id_", i)), NULL,
              placeholder = sprintf("Barcode (optional, default: %s)", auto_id),
              value = isolate(input[[paste0("bc_id_", i)]] %||% "")
            )
          ),
          if (mixed) div(
            class = "col-md-3",
            selectInput(
              ns(paste0("bc_site_", i)), NULL,
              choices = c("Sample type..." = "", SITE_CHOICES),
              selected = isolate(input[[paste0("bc_site_", i)]] %||% "")
            )
          )
        )
      }))
    })

    # Barcode ID for row i (blank falls back to the auto-sequential id)
    row_barcode <- function(i) {
      bc <- trimws(input[[paste0("bc_id_", i)]] %||% "")
      if (nchar(bc) == 0) bc <- sprintf("barcode%02d", i)
      normalize_barcode_id(bc)
    }

    # Collect sample_sites (barcode -> sample type) for mixed runs
    get_sample_sites <- reactive({
      if (!is_mixed()) return(NULL)
      n <- n_barcodes()
      if (n == 0L) return(NULL)
      m <- list()
      for (i in seq_len(n)) {
        site <- input[[paste0("bc_site_", i)]] %||% ""
        if (nchar(site) == 0) next
        m[[row_barcode(i)]] <- site
      }
      if (length(m) == 0L) NULL else m
    })

    # Sample types currently used by the rows (mixed runs)
    used_sites <- reactive({
      sites <- unlist(or_empty(get_sample_sites()))
      unname(SITE_CHOICES[SITE_CHOICES %in% sites])
    })

    # One Kraken2 DB + confidence + min-hit-groups block per sample type in use
    output$site_db_rows <- renderUI({
      sites <- used_sites()
      if (length(sites) == 0) {
        return(tags$small(class = "text-muted",
          "Add samples below and choose each sample's type to set a database per type."))
      }
      tagList(lapply(sites, function(site) {
        label <- names(SITE_CHOICES)[SITE_CHOICES == site]
        d <- SITE_KRAKEN_DEFAULTS[[site]]
        div(
          class = "mb-3",
          tags$label(class = "form-label", paste(label, "Kraken2 Database")),
          div(
            class = "file-browse-group",
            div(
              class = "drop-zone",
              div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
              actionButton(ns(paste0("site_db_browse_", site)), "Browse",
                class = "btn btn-outline-secondary"
              )
            ),
            textInput(ns(paste0("site_db_", site)), NULL,
              placeholder = sprintf("/path/to/%s/kraken2/db", site),
              value = isolate(input[[paste0("site_db_", site)]] %||% ""),
              width = "100%"
            )
          ),
          div(
            class = "row",
            div(
              class = "col-md-6",
              tags$label(class = "form-label", "Confidence Threshold"),
              numericInput(ns(paste0("site_conf_", site)), NULL,
                value = isolate(input[[paste0("site_conf_", site)]]) %||% d$conf,
                min = 0, max = 1, step = 0.01)
            ),
            div(
              class = "col-md-6",
              tags$label(class = "form-label", "Minimum Hit Groups"),
              numericInput(ns(paste0("site_mhg_", site)), NULL,
                value = isolate(input[[paste0("site_mhg_", site)]]) %||% d$mhg,
                min = 1, max = 100, step = 1)
            )
          )
        )
      }))
    })

    get_site_dbs <- reactive({
      m <- list()
      for (site in used_sites()) {
        p <- trimws(input[[paste0("site_db_", site)]] %||% "")
        if (nchar(p) > 0) m[[site]] <- p
      }
      if (length(m) == 0L) NULL else m
    })

    get_site_params <- reactive({
      m <- list()
      for (site in used_sites()) {
        d <- SITE_KRAKEN_DEFAULTS[[site]]
        m[[site]] <- list(
          confidence         = as.numeric(input[[paste0("site_conf_", site)]] %||% d$conf),
          minimum_hit_groups = as.integer(input[[paste0("site_mhg_", site)]] %||% d$mhg)
        )
      }
      if (length(m) == 0L) NULL else m
    })

    # Collect sample_map (barcode -> sample name) from current sample rows.
    # Barcode is optional per row: blank falls back to the auto-sequential id.
    get_sample_map <- reactive({
      n <- n_barcodes()
      if (n == 0L) return(NULL)
      m <- list()
      for (i in seq_len(n)) {
        nm <- trimws(input[[paste0("bc_name_", i)]] %||% "")
        if (nchar(nm) == 0) next
        m[[row_barcode(i)]] <- nm
      }
      if (length(m) == 0L) NULL else m
    })

    # Auto-detect Dorado paths from wizard-installed locations
    observe({
      repo_root <- dirname(getwd())
      dorado_candidates <- c(
        file.path(repo_root, "main", "tools", "dorado", "bin", "dorado"),
        file.path(repo_root, "tools", "dorado", "bin", "dorado")
      )
      for (candidate in dorado_candidates) {
        if (file.exists(candidate) && nchar(input$dorado_bin) == 0) {
          updateTextInput(session, "dorado_bin", value = candidate)
          models_dir <- file.path(dirname(dirname(candidate)), "models")
          if (dir.exists(models_dir) && nchar(input$dorado_models_dir) == 0) {
            updateTextInput(session, "dorado_models_dir", value = models_dir)
          }
          break
        }
      }
    })

    # --- Additional output directory ---
    # Text field: sync to shared whenever the user types or drag-drops a path
    observeEvent(input$extra_output_dir, {
      val <- trimws(input$extra_output_dir %||% "")
      shared$additional_output_dir <- if (nchar(val) > 0) val else NULL
    }, ignoreInit = TRUE)

    # --- Display dynamic values ---
    output$quality_threshold_display <- renderText({ as.character(input$quality_threshold) })
    output$min_read_length_display   <- renderText({ as.character(input$min_read_length) })

    # --- Summary panel ---
    output$summary_pipeline <- renderText({
      switch(input$pipeline,
        "lr_amp"  = "Long Read 16S Amplicon (Emu)",
        "lr_meta" = "Long Read Metagenomics",
        input$pipeline
      )
    })

    output$summary_technology <- renderText({
      switch(input$lr_technology,
        "ont"    = "Oxford Nanopore (ONT)",
        "pacbio" = "PacBio",
        toupper(input$lr_technology)
      )
    })

    output$summary_format <- renderText({ toupper(input$input_format) })

    output$summary_sample_type <- renderText({ tools::toTitleCase(input$sample_type) })

    output$summary_run_scope <- renderText({
      switch(input$run_scope,
        "full" = "Full Pipeline",
        "qc"   = "QC Only",
        tools::toTitleCase(input$run_scope)
      )
    })

    # --- Validation ---
    validate_inputs <- reactive({
      errors <- final_dir_errors(input$extra_output_dir)
      kit_chk <- kit_field_check(input$barcoding_kit, input$ligation_kit)
      errors <- c(errors, kit_chk$errors)

      if (nchar(input$input_path) == 0) {
        errors <- c(errors, "Input path is required")
      }

      kraken_db_provided <- nchar(input$kraken_db) > 0 ||
        (nchar(input$external_db_dir %||% "") > 0 &&
         (input$database_type %||% "auto") %in% c("auto", "kraken2"))

      if (is_mixed()) {
        n <- n_barcodes()
        if (n == 0L) {
          errors <- c(errors, "Mixed sample types: add the samples in this run under Samples")
        } else {
          unset <- which(vapply(seq_len(n), function(i) nchar(input[[paste0("bc_site_", i)]] %||% "") == 0, logical(1)))
          if (length(unset) > 0) {
            errors <- c(errors, sprintf("Choose a sample type for sample row(s): %s", paste(unset, collapse = ", ")))
          }
          bcs <- vapply(seq_len(n), row_barcode, character(1))
          if (any(duplicated(bcs))) {
            errors <- c(errors, sprintf("Barcode used more than once: %s", paste(unique(bcs[duplicated(bcs)]), collapse = ", ")))
          }
        }
        if (input$pipeline == "lr_meta") {
          site_dbs <- or_empty(get_site_dbs())
          missing <- setdiff(used_sites(), names(site_dbs))
          if (length(missing) > 0 && !kraken_db_provided) {
            labels <- names(SITE_CHOICES)[match(missing, SITE_CHOICES)]
            errors <- c(errors, sprintf("Kraken2 database required for: %s (or set the Kraken2 Database Path as a fallback)",
                                        paste(labels, collapse = ", ")))
          }
          errors <- c(errors, mixed_db_errors(site_dbs, trimws(input$comparison_db %||% ""),
                                              trimws(input$kraken_db %||% "")))
        }
      } else if (input$pipeline == "lr_meta") {
        if (!kraken_db_provided) {
          errors <- c(errors, "Kraken2 database path is required for metagenomics")
        }
      }

      if (input$input_format %in% c("fast5", "pod5") && nchar(input$barcoding_kit) == 0) {
        errors <- c(errors, "Barcoding Kit is required for FAST5/POD5 input (Dorado demultiplexing)")
      }

      warnings <- kit_chk$warnings
      if (input$pipeline == "lr_meta") {
        warnings <- c(warnings, kraken_db_slow_warnings(kraken_db_paths(
          input$kraken_db,
          if (is_mixed()) or_empty(get_site_dbs()) else list(),
          if (is_mixed()) input$comparison_db else "")))
      }

      list(valid = length(errors) == 0, errors = errors, warnings = warnings)
    })

    output$validation_messages <- renderUI({
      val <- validate_inputs()

      status <- if (val$valid) {
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
      tagList(status, slow_db_alert(val$warnings))
    })

    # --- Aggregate output checkboxes into output_selected vector ---
    get_output_selected <- reactive({
      selected <- c(
        if (isTRUE(input$output_raw_csv))         "raw_csv",
        if (isTRUE(input$output_pie_chart))       "pie_chart",
        if (isTRUE(input$output_heatmap))         "heatmap",
        if (isTRUE(input$output_stacked_bar))     "stacked_bar",
        if (isTRUE(input$output_quality_reports)) "quality_reports"
      )
      if (length(selected) == 0) c("all") else selected
    })

    # Kit values from Input Configuration section
    # - FAST5/POD5: required for Dorado basecalling
    # - FASTQ: optional for demultiplexing
    get_effective_barcoding_kit <- reactive({
      input$barcoding_kit
    })

    get_effective_ligation_kit <- reactive({
      input$ligation_kit
    })

    # --- Build CLI command (dry-run preview only) ---
    build_command <- reactive({
      cmd <- c(
        file.path(dirname(getwd()), "stamina-biome"),
        "run",
        "-p", input$pipeline,
        "-i", input$input_path
      )

      cmd <- c(cmd, "-o", file.path(dirname(getwd()), "outputs"))
      if (nchar(input$run_name) > 0)    cmd <- c(cmd, "--run-name", input$run_name)

      cmd <- c(cmd, "--sample-type", input$sample_type)
      cmd <- c(cmd, "--threads",     as.character(input$threads))
      cmd <- c(cmd, "--technology",  toupper(input$lr_technology %||% "ont"))

      if (!is.null(input$run_scope) && nchar(input$run_scope) > 0) {
        cmd <- c(cmd, "--scope", input$run_scope)
      }

      if (input$input_format %in% c("fast5", "pod5")) {
        if (nchar(input$dorado_bin) > 0)        cmd <- c(cmd, "--dorado-bin",        input$dorado_bin)
        if (nchar(input$dorado_models_dir) > 0) cmd <- c(cmd, "--dorado-models-dir", input$dorado_models_dir)
        if (nchar(input$dorado_model) > 0)      cmd <- c(cmd, "--dorado-model",      input$dorado_model)
        if (nchar(input$barcoding_kit) > 0)     cmd <- c(cmd, "--barcoding-kit",     input$barcoding_kit)
        if (nchar(input$ligation_kit) > 0)      cmd <- c(cmd, "--ligation-kit",      input$ligation_kit)
      }

      if (input$pipeline == "lr_meta" && nchar(input$kraken_db) > 0) {
        cmd <- c(cmd, "--db", input$kraken_db)
      }

      if (is_mixed()) {
        sites <- or_empty(get_sample_sites())
        if (length(sites) > 0) {
          cmd <- c(cmd, "--sample-sheet", "<sample_sheet.tsv: barcode/sample_name/site>")
        }
        if (input$pipeline == "lr_meta") {
          site_dbs <- or_empty(get_site_dbs())
          for (site in names(site_dbs)) cmd <- c(cmd, "--site-db", paste0(site, "=", site_dbs[[site]]))
          cmp <- trimws(input$comparison_db %||% "")
          if (nchar(cmp) > 0) cmd <- c(cmd, "--comparison-db", cmp)
        }
      }

      if (input$sample_type %in% c("vaginal", "mixed") && !is.null(input$valencia)) {
        cmd <- c(cmd, "--valencia", input$valencia)
      }

      cmd <- c(cmd, "--quality-threshold", as.character(input$quality_threshold))
      cmd <- c(cmd, "--min-length",        as.character(input$min_read_length))

      if (isTRUE(input$trim_adapter)) cmd <- c(cmd, "--trim-adapter")
      if (isTRUE(input$demultiplex))  cmd <- c(cmd, "--demultiplex")

      cmd
    })

    # --- Dry run preview ---
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

    # --- Run pipeline ---
    observeEvent(input$run_pipeline, {
      val <- validate_inputs()

      if (!val$valid) {
        showNotification(
          paste("Validation errors:", paste(val$errors, collapse = "; ")),
          type = "error", duration = 10
        )
        return()
      }

      if (length(val$warnings) > 0) {
        showNotification(paste(val$warnings, collapse = " "),
                         type = "warning", duration = 20)
      }

      # Capture this module's own output-dir field fresh, right as the run starts.
      # shared$additional_output_dir is a single global value also written to by the
      # SR module's own field-change observer — without re-asserting it here at
      # run-time, visiting the other tab (even with its field empty) can silently
      # clobber whatever this module's field held.
      extra_output_dir_val <- trimws(input$extra_output_dir %||% "")
      shared$additional_output_dir <- if (nchar(extra_output_dir_val) > 0) extra_output_dir_val else NULL
      cat("[DEBUG] shared$additional_output_dir (lr_meta run):", if (is.null(shared$additional_output_dir)) "(none)" else shared$additional_output_dir, "\n")

      run_id <- if (!is.null(input$run_name) && nchar(trimws(input$run_name)) > 0) {
        sanitized <- trimws(input$run_name)
        sanitized <- gsub("[\\/: *?\"<>|\\\\]", "_", sanitized)
        sanitized <- gsub("\\s+", "_", sanitized)
        sanitized
      } else {
        format(Sys.time(), "%Y%m%d_%H%M%S")
      }

      params <- list(
        run_id            = run_id,
        pipeline          = input$pipeline,
        technology        = input$lr_technology,
        input_format      = input$input_format,
        input_path        = input$input_path,
        output_dir        = file.path(dirname(getwd()), "outputs"),
        run_scope         = input$run_scope,
        quality_threshold = input$quality_threshold,
        min_read_length   = input$min_read_length,
        threads           = input$threads,
        sample_type       = input$sample_type,
        trim_adapter      = input$trim_adapter,
        demultiplex       = input$demultiplex,
        primer_sequences  = input$primer_sequences,
        barcode_sequences = input$barcode_sequences,
        barcoding_kit     = get_effective_barcoding_kit(),
        ligation_kit      = get_effective_ligation_kit(),
        kraken_db              = input$kraken_db,
        kraken_confidence      = input$kraken_confidence,
        kraken_min_hit_groups  = input$kraken_min_hit_groups,
        emu_min_pid            = input$emu_min_pid,
        external_db_dir        = input$external_db_dir,
        database_type          = input$database_type,
        human_depletion        = input$human_depletion,
        valencia          = input$valencia,
        dorado_bin        = input$dorado_bin,
        dorado_models_dir = input$dorado_models_dir,
        dorado_model      = input$dorado_model,
        output_selected   = get_output_selected(),
        enable_postprocess = any(c(isTRUE(input$output_raw_csv), isTRUE(input$output_pie_chart),
                                   isTRUE(input$output_heatmap), isTRUE(input$output_stacked_bar),
                                   isTRUE(input$output_quality_reports))),
        sample_map        = get_sample_map(),
        sample_sites      = get_sample_sites(),
        site_dbs          = if (is_mixed() && input$pipeline == "lr_meta") get_site_dbs() else NULL,
        site_params       = if (is_mixed() && input$pipeline == "lr_meta") get_site_params() else NULL,
        comparison_db     = if (is_mixed() && input$pipeline == "lr_meta") trimws(input$comparison_db %||% "") else "",
        bracken_readlen   = shared$bracken_readlen %||% "auto"
      )

      config <- if (input$pipeline == "lr_amp") {
        generate_lr_amp_config(params)
      } else {
        generate_lr_meta_config(params)
      }

      # The pipeline moves the finished run here (outputs/ keeps a link to it)
      final_dir <- resolve_final_dir(input$extra_output_dir)
      if (nzchar(final_dir)) config$run$final_dir <- final_dir

      config_file <- save_config(config, run_id)

      shared$current_run <- list(
        run_id      = run_id,
        pipeline    = input$pipeline,
        config_file = config_file,
        run_name    = input$run_name,
        sample_type = input$sample_type
      )

      shared$run_status <- "ready"
    })
  })
}
