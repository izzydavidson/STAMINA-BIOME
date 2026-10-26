# Configuration Generator Utilities
# Functions to generate pipeline configurations that match the run.schema.json format

get_outputs_directory <- function() {
  repo_root <- dirname(getwd())
  file.path(repo_root, "outputs")
}

# Helper: resolve a postprocess step flag
# step_key: the value in output_selected (e.g. "pie_chart")
# postprocess_enabled: 1L or 0L from the checkbox
pp_step <- function(key, output_selected, postprocess_enabled) {
  if (postprocess_enabled == 1L && key %in% output_selected) 1L else 0L
}

# Helper: format a postprocess step value for cat() — handles both plain int and
# list form (list(enabled=1L, params=list(...))) produced when sample_map is set.
.fmt_step <- function(x) {
  if (is.list(x)) paste0(x$enabled, " [+params]") else as.character(x)
}

generate_sr_amp_config <- function(params) {
  cat("\n========== BUILDING SR_AMP CONFIG ==========\n")

  # --- technology ---
  # UI: selectInput("technology") -> "illumina"|"iontorrent"|"bgi"
  # Config: config$technology -> "ILLUMINA"|"IONTORRENT"|"BGI"
  tech_map <- c(
    "illumina"   = "ILLUMINA",
    "iontorrent" = "IONTORRENT",
    "bgi"        = "BGI"
  )
  technology <- tech_map[params$technology] %||% "ILLUMINA"
  cat("[WIRE] technology:", params$technology, "->", unname(technology), "\n")

  # --- input style + files ---
  # UI: checkboxInput("paired_end") -> TRUE/FALSE
  # Config: config$input$style, config$input$fastq_r1, config$input$fastq_r2
  input_style <- if (isTRUE(params$paired_end)) "FASTQ_PAIRED" else "FASTQ_SINGLE"
  cat("[WIRE] paired_end:", isTRUE(params$paired_end), "-> input.style:", input_style, "\n")

  input_obj <- list(style = input_style)
  if (isTRUE(params$paired_end)) {
    input_obj$fastq_r1 <- trimws(params$input_r1)
    input_obj$fastq_r2 <- trimws(params$input_r2)
    cat("[WIRE] input.fastq_r1:", trimws(params$input_r1), "\n")
    cat("[WIRE] input.fastq_r2:", trimws(params$input_r2), "\n")
  } else {
    input_obj$fastq_r1 <- trimws(params$input_path)
    cat("[WIRE] input.fastq_r1:", trimws(params$input_path), "\n")
  }

  # --- primers ---
  # UI: textAreaInput("primer_sequences") -> newline-separated sequences
  # Config: config$qiime2$primers$forward, config$qiime2$primers$reverse
  primer_forward <- NULL
  primer_reverse <- NULL
  if (!is.null(params$primer_sequences) && nchar(trimws(params$primer_sequences)) > 0) {
    primer_lines <- strsplit(params$primer_sequences, "\n")[[1]]
    primer_lines <- trimws(primer_lines)
    primer_lines <- primer_lines[nchar(primer_lines) > 0]
    if (length(primer_lines) >= 1) primer_forward <- primer_lines[1]
    if (length(primer_lines) >= 2) primer_reverse <- primer_lines[2]
    cat("[WIRE] qiime2.primers.forward:", primer_forward, "\n")
    cat("[WIRE] qiime2.primers.reverse:", primer_reverse, "\n")
  } else {
    cat("[WIRE] qiime2.primers: none (skipping primer trimming)\n")
  }

  # --- barcode sequences ---
  # UI: textAreaInput("barcode_sequences") -> newline-separated sequences
  # Config: config$input$barcodes$sequences
  barcode_sequences <- NULL
  if (!is.null(params$barcode_sequences) && nchar(trimws(params$barcode_sequences)) > 0) {
    barcode_lines <- strsplit(params$barcode_sequences, "\n")[[1]]
    barcode_lines <- trimws(barcode_lines)
    barcode_lines <- barcode_lines[nchar(barcode_lines) > 0]
    if (length(barcode_lines) > 0) {
      barcode_sequences <- barcode_lines
      cat("[WIRE] input.barcodes.sequences:", length(barcode_lines), "sequences\n")
    }
  }

  # --- output selected ---
  # UI: checkboxInput("output_raw_csv/pie_chart/heatmap/stacked_bar/quality_reports")
  # -> aggregated in server as output_selected vector
  # Config: config$output$selected (string array for pipeline reference)
  output_selected <- if (!is.null(params$output_selected) && length(params$output_selected) > 0) {
    as.character(params$output_selected)
  } else {
    c("all")
  }
  cat("[WIRE] output.selected:", paste(output_selected, collapse=", "), "\n")

  # --- specimen / sample type ---
  # UI: selectInput("sample_type") -> "vaginal"|"gut"|"oral"|"skin"|"other"
  # Config: config$specimen, config$params$common$specimen
  specimen <- params$sample_type %||% "other"
  cat("[WIRE] specimen:", specimen, "\n")

  # --- threads ---
  # UI: numericInput("threads") controlled by checkboxInput("manually_allocate_threads")
  # -> threads_value computed in server (4 if not manual, input$threads if manual)
  # Config: config$resources$threads, config$qiime2$dada2$n_threads
  threads <- as.integer(params$threads %||% 4L)
  cat("[WIRE] resources.threads:", threads, "| qiime2.dada2.n_threads:", threads, "\n")

  # --- quality threshold ---
  # UI: sliderInput("quality_threshold") min=0, max=40, default=20
  # Config: config$params$common$min_qscore
  quality_threshold <- as.integer(params$quality_threshold %||% 20L)
  cat("[WIRE] params.common.min_qscore:", quality_threshold, "\n")

  # --- minimum read length ---
  # UI: sliderInput("min_read_length") min=20, max=300, default=50
  # Config: config$params$common$min_read_length
  # Note: slider always provides a value so this is never NULL
  min_read_length <- if (!is.null(params$min_read_length)) as.integer(params$min_read_length) else NULL
  cat("[WIRE] params.common.min_read_length:", if (is.null(min_read_length)) "(omitted)" else min_read_length, "\n")

  # --- trim adapter ---
  # UI: checkboxInput("trim_adapter") default=TRUE
  # Config: config$params$common$trim_adapter (logical: true/false)
  trim_adapter <- if (!is.null(params$trim_adapter)) as.logical(params$trim_adapter) else NULL
  cat("[WIRE] params.common.trim_adapter:", if (is.null(trim_adapter)) "(omitted)" else trim_adapter, "\n")

  # --- demultiplex ---
  # UI: checkboxInput("demultiplex") default=FALSE
  # Config: config$params$common$demultiplex (logical: true/false)
  demultiplex <- if (!is.null(params$demultiplex)) as.logical(params$demultiplex) else NULL
  cat("[WIRE] params.common.demultiplex:", if (is.null(demultiplex)) "(omitted)" else demultiplex, "\n")

  # --- run scope ---
  # UI: selectInput("run_scope") -> "full"|"qc"|"analysis"
  # Config: config$run$scope
  run_scope <- params$run_scope %||% NULL
  cat("[WIRE] run.scope:", if (is.null(run_scope)) "(omitted)" else run_scope, "\n")

  # --- barcoding kit ---
  # UI: textInput("barcoding_kit")
  # Config: config$tools$barcoding_kit
  barcoding_kit <- if (!is.null(params$barcoding_kit) && nchar(trimws(params$barcoding_kit)) > 0) {
    trimws(params$barcoding_kit)
  } else {
    NULL
  }
  cat("[WIRE] tools.barcoding_kit:", if (is.null(barcoding_kit)) "(omitted)" else barcoding_kit, "\n")

  # --- DADA2 truncation lengths ---
  # UI: numericInput("dada2_trunc_f") default=220, numericInput("dada2_trunc_r") default=200
  # Config: config$qiime2$dada2$trunc_len_f, config$qiime2$dada2$trunc_len_r
  dada2_trunc_f <- as.integer(params$dada2_trunc_f %||% 220L)
  dada2_trunc_r <- as.integer(params$dada2_trunc_r %||% 200L)
  cat("[WIRE] qiime2.dada2.trunc_len_f:", dada2_trunc_f, "| trunc_len_r:", dada2_trunc_r, "\n")

  # --- SILVA classifier auto-detection ---
  # Not a UI control - auto-detected from filesystem
  # Config: config$qiime2$classifier$qza
  repo_root <- dirname(getwd())
  classifier_path <- file.path(repo_root, "main", "data", "reference", "qiime2", "silva-138-99-nb-classifier.qza")
  if (file.exists(classifier_path)) {
    cat("[WIRE] qiime2.classifier.qza: auto-detected at", classifier_path, "\n")
  } else {
    classifier_path <- ""
    cat("[WIRE] qiime2.classifier.qza: NOT FOUND - taxonomy will be skipped\n")
  }

  # --- VALENCIA centroids auto-detection ---
  # Not a UI control - auto-detected from filesystem
  # Config: config$valencia$centroids_csv (only written when specimen == "vaginal")
  valencia_centroids_candidates <- c(
    file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv"),
    file.path(repo_root, "main", "tools", "VALENCIA", "CST_centroids_012920.csv")
  )
  valencia_centroids_path <- ""
  for (candidate in valencia_centroids_candidates) {
    if (file.exists(candidate)) {
      valencia_centroids_path <- candidate
      cat("[WIRE] valencia.centroids_csv: auto-detected at", valencia_centroids_path, "\n")
      break
    }
  }
  if (valencia_centroids_path == "") {
    cat("[WIRE] valencia.centroids_csv: NOT FOUND - using default path\n")
    valencia_centroids_path <- file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv")
  }

  # --- postprocess enabled ---
  # UI: checkboxInput("enable_postprocess") default=TRUE
  # Config: config$postprocess$enabled (integer: 1 or 0)
  # CRITICAL: backend checks postprocess.enabled == 1 (integer, not boolean)
  postprocess_enabled <- if (!is.null(params$enable_postprocess) && isTRUE(params$enable_postprocess)) 1L else 0L
  cat("[WIRE] postprocess.enabled:", postprocess_enabled, "(from enable_postprocess =", isTRUE(params$enable_postprocess), ")\n")

  # --- postprocess steps ---
  # Backend reads individual step flags from postprocess.steps.* NOT from output.selected.
  # Key name mapping (UI value in output_selected -> backend postprocess.steps key):
  #   "heatmap"     -> steps$heatmap
  #   "pie_chart"   -> steps$piechart     (backend uses no underscore)
  #   "stacked_bar" -> steps$stacked_bar
  #   "raw_csv"     -> steps$results_csv  (different name in backend)
  #   "quality_reports" -> no postprocess step (handled by pipeline QC section)
  # results_csv is ALWAYS enabled when postprocess is on — abundance tables are
  # essential output regardless of which optional output checkboxes are ticked.
  # Other visual steps respect the user's checkbox selection.
  postprocess_steps <- list(
    heatmap            = pp_step("heatmap",     output_selected, postprocess_enabled),
    piechart           = pp_step("pie_chart",   output_selected, postprocess_enabled),  # pie_chart -> piechart
    stacked_bar        = pp_step("stacked_bar", output_selected, postprocess_enabled),
    results_csv        = postprocess_enabled,  # always on — tables always generated
    relative_abundance = 0L
    # valencia is added below after VALENCIA section resolves valencia_enabled
  )
  cat("[WIRE] postprocess.steps.heatmap:", postprocess_steps$heatmap, "\n")
  cat("[WIRE] postprocess.steps.piechart:", postprocess_steps$piechart, "(from 'pie_chart' in output_selected)\n")
  cat("[WIRE] postprocess.steps.stacked_bar:", postprocess_steps$stacked_bar, "\n")
  cat("[WIRE] postprocess.steps.results_csv:", postprocess_steps$results_csv, "(always on)\n")

  # --- build params.common ---
  params_common <- list(
    min_qscore  = quality_threshold,
    remove_host = 0L,             # sr_amp: human depletion not applicable; hardcoded 0
    specimen    = specimen
  )
  if (!is.null(min_read_length)) params_common$min_read_length <- min_read_length
  if (!is.null(trim_adapter))    params_common$trim_adapter <- trim_adapter
  if (!is.null(demultiplex))     params_common$demultiplex  <- demultiplex

  # --- assemble config ---
  config <- list(
    pipeline_id = "sr_amp",

    run = list(
      work_dir        = params$output_dir,
      run_id          = params$run_id,
      force_overwrite = 1L
    ),

    technology = unname(technology),
    specimen   = specimen,

    input = input_obj,

    resources = list(
      threads = threads
    ),

    params = list(
      common = params_common
    ),

    qiime2 = list(
      sample_id  = params$run_id,
      classifier = list(
        qza = classifier_path
      ),
      dada2 = list(
        trim_left_f = 0L,
        trim_left_r = 0L,
        trunc_len_f = dada2_trunc_f,
        trunc_len_r = dada2_trunc_r,
        n_threads   = threads
      )
    ),

    output = list(
      selected = output_selected
    ),

    # postprocess: ALWAYS written; backend reads postprocess.enabled AND postprocess.steps.*
    postprocess = list(
      enabled = postprocess_enabled,
      steps   = postprocess_steps
    )
  )

  # --- run scope (conditional) ---
  if (!is.null(run_scope)) {
    config$run$scope <- run_scope
  }

  # --- primers (conditional) ---
  if (!is.null(primer_forward) || !is.null(primer_reverse)) {
    primers_obj <- list()
    if (!is.null(primer_forward)) primers_obj$forward <- primer_forward
    if (!is.null(primer_reverse)) primers_obj$reverse <- primer_reverse
    config$qiime2$primers <- primers_obj
  }

  # --- barcode sequences (conditional) ---
  if (!is.null(barcode_sequences)) {
    if (is.null(config$input$barcodes)) config$input$barcodes <- list()
    config$input$barcodes$sequences <- barcode_sequences
  }

  # --- barcoding kit (conditional) ---
  if (!is.null(barcoding_kit)) {
    if (is.null(config$tools)) config$tools <- list()
    config$tools$barcoding_kit <- barcoding_kit
  }

  # --- VALENCIA (conditional: vaginal only) ---
  # UI: selectInput("valencia") -> "yes"|"no" (only shown when sample_type == "vaginal")
  # Config: config$valencia$enabled (1L or 0L), config$valencia$centroids_csv
  # Also controls: config$postprocess$steps$valencia
  if (specimen == "vaginal") {
    valencia_enabled <- if (!is.null(params$valencia) && params$valencia == "yes") 1L else 0L
    config$valencia <- list(
      enabled       = valencia_enabled,
      mode          = "auto",
      centroids_csv = valencia_centroids_path
    )
    cat("[WIRE] valencia.enabled:", valencia_enabled, "| centroids_csv:", valencia_centroids_path, "\n")

    # Wire VALENCIA postprocess step: only enabled when postprocess is on AND VALENCIA is enabled
    config$postprocess$steps$valencia <- if (postprocess_enabled == 1L && valencia_enabled == 1L) 1L else 0L
    cat("[WIRE] postprocess.steps.valencia:", config$postprocess$steps$valencia, "\n")
  } else {
    cat("[WIRE] valencia: omitted (specimen is", specimen, "not vaginal)\n")
    config$postprocess$steps$valencia <- 0L
  }

  # --- external DB (conditional: sr_amp uses generic external_db path) ---
  # UI: textInput("external_db_dir")
  # Config: config$host$resources$external_db$host_path
  if (!is.null(params$external_db_dir) && nchar(trimws(params$external_db_dir)) > 0) {
    if (is.null(config$host)) config$host <- list()
    if (is.null(config$host$resources)) config$host$resources <- list()
    config$host$resources$external_db <- list(
      host_path = trimws(params$external_db_dir)
    )
    cat("[WIRE] host.resources.external_db.host_path:", trimws(params$external_db_dir), "\n")
  }

  # --- sample_map (barcode → sample name) ---
  sample_map <- if (!is.null(params$sample_map) && length(params$sample_map) > 0) {
    params$sample_map
  } else NULL

  if (!is.null(sample_map)) {
    config$sample_map   <- sample_map
    sample_sheet_path   <- file.path(params$output_dir, params$run_id, "sample_sheet.tsv")
    config$sample_sheet <- sample_sheet_path

    for (sn in c("heatmap", "piechart", "stacked_bar", "results_csv")) {
      current_val <- config$postprocess$steps[[sn]]
      if (!is.null(current_val) && identical(current_val, 1L)) {
        config$postprocess$steps[[sn]] <- list(
          enabled = 1L,
          params  = list(sample_sheet = sample_sheet_path)
        )
      }
    }
    cat("[WIRE] sample_map:", length(sample_map), "entries\n")
    cat("[WIRE] sample_sheet:", sample_sheet_path, "\n")
  }

  # --- pre-return audit ---
  cat("\n[AUDIT] sr_amp config field check:\n")
  cat("  pipeline_id:                        ", config$pipeline_id, "\n")
  cat("  run.work_dir:                       ", config$run$work_dir, "\n")
  cat("  run.run_id:                         ", config$run$run_id, "\n")
  cat("  run.scope:                          ", if (!is.null(config$run$scope)) config$run$scope else "(none)", "\n")
  cat("  technology:                         ", config$technology, "\n")
  cat("  specimen:                           ", config$specimen, "\n")
  cat("  input.style:                        ", config$input$style, "\n")
  cat("  resources.threads:                  ", config$resources$threads, "\n")
  cat("  params.common.min_qscore:           ", config$params$common$min_qscore, "\n")
  cat("  params.common.min_read_length:      ", if (!is.null(config$params$common$min_read_length)) config$params$common$min_read_length else "(omitted)", "\n")
  cat("  params.common.trim_adapter:         ", if (!is.null(config$params$common$trim_adapter)) config$params$common$trim_adapter else "(omitted)", "\n")
  cat("  params.common.demultiplex:          ", if (!is.null(config$params$common$demultiplex)) config$params$common$demultiplex else "(omitted)", "\n")
  cat("  params.common.remove_host:          ", config$params$common$remove_host, "\n")
  cat("  qiime2.dada2.trunc_len_f:           ", config$qiime2$dada2$trunc_len_f, "\n")
  cat("  qiime2.dada2.trunc_len_r:           ", config$qiime2$dada2$trunc_len_r, "\n")
  cat("  qiime2.dada2.n_threads:             ", config$qiime2$dada2$n_threads, "\n")
  cat("  output.selected:                    ", paste(config$output$selected, collapse=", "), "\n")
  cat("  postprocess.enabled:                ", config$postprocess$enabled, "[TYPE:", class(config$postprocess$enabled), "]\n")
  cat("  postprocess.steps.heatmap:          ", .fmt_step(config$postprocess$steps$heatmap), "\n")
  cat("  postprocess.steps.piechart:         ", .fmt_step(config$postprocess$steps$piechart), "\n")
  cat("  postprocess.steps.stacked_bar:      ", .fmt_step(config$postprocess$steps$stacked_bar), "\n")
  cat("  postprocess.steps.results_csv:      ", .fmt_step(config$postprocess$steps$results_csv), "\n")
  cat("  postprocess.steps.relative_abundance:", config$postprocess$steps$relative_abundance, "\n")
  cat("  postprocess.steps.valencia:         ", config$postprocess$steps$valencia, "\n")
  if (!is.null(config$valencia)) {
    cat("  valencia.enabled:                   ", config$valencia$enabled, "\n")
    cat("  valencia.centroids_csv:             ", config$valencia$centroids_csv, "\n")
  }
  cat("========== SR_AMP CONFIG COMPLETE ==========\n\n")

  config
}

generate_sr_meta_config <- function(params) {
  cat("\n========== BUILDING SR_META CONFIG ==========\n")

  # --- technology ---
  tech_map <- c(
    "illumina"   = "ILLUMINA",
    "iontorrent" = "IONTORRENT",
    "bgi"        = "BGI"
  )
  technology <- tech_map[params$technology] %||% "ILLUMINA"
  cat("[WIRE] technology:", params$technology, "->", unname(technology), "\n")

  # --- input style + files ---
  input_style <- if (isTRUE(params$paired_end)) "FASTQ_PAIRED" else "FASTQ_SINGLE"
  cat("[WIRE] paired_end:", isTRUE(params$paired_end), "-> input.style:", input_style, "\n")

  input_obj <- list(style = input_style)
  if (isTRUE(params$paired_end)) {
    input_obj$fastq_r1 <- trimws(params$input_r1)
    input_obj$fastq_r2 <- trimws(params$input_r2)
    cat("[WIRE] input.fastq_r1:", trimws(params$input_r1), "\n")
    cat("[WIRE] input.fastq_r2:", trimws(params$input_r2), "\n")
  } else {
    input_obj$fastq_r1 <- trimws(params$input_path)
    cat("[WIRE] input.fastq_r1:", trimws(params$input_path), "\n")
  }

  # --- output selected ---
  output_selected <- if (!is.null(params$output_selected) && length(params$output_selected) > 0) {
    as.character(params$output_selected)
  } else {
    c("all")
  }
  cat("[WIRE] output.selected:", paste(output_selected, collapse=", "), "\n")

  # --- specimen ---
  specimen <- params$sample_type %||% "other"
  cat("[WIRE] specimen:", specimen, "\n")

  # --- threads ---
  threads <- as.integer(params$threads %||% 4L)
  cat("[WIRE] resources.threads:", threads, "\n")

  # --- quality threshold ---
  quality_threshold <- as.integer(params$quality_threshold %||% 20L)
  cat("[WIRE] params.common.min_qscore:", quality_threshold, "\n")

  # --- minimum read length ---
  min_read_length <- if (!is.null(params$min_read_length)) as.integer(params$min_read_length) else NULL
  cat("[WIRE] params.common.min_read_length:", if (is.null(min_read_length)) "(omitted)" else min_read_length, "\n")

  # --- trim adapter ---
  trim_adapter <- if (!is.null(params$trim_adapter)) as.logical(params$trim_adapter) else NULL
  cat("[WIRE] params.common.trim_adapter:", if (is.null(trim_adapter)) "(omitted)" else trim_adapter, "\n")

  # --- demultiplex ---
  demultiplex <- if (!is.null(params$demultiplex)) as.logical(params$demultiplex) else NULL
  cat("[WIRE] params.common.demultiplex:", if (is.null(demultiplex)) "(omitted)" else demultiplex, "\n")

  # --- run scope ---
  run_scope <- params$run_scope %||% NULL
  cat("[WIRE] run.scope:", if (is.null(run_scope)) "(omitted)" else run_scope, "\n")

  # --- human depletion ---
  # UI: checkboxInput("human_depletion") default=FALSE (sr_meta only)
  # Config: config$params$common$remove_host (integer: 1 or 0)
  human_depletion <- if (!is.null(params$human_depletion) && isTRUE(params$human_depletion)) 1L else 0L
  cat("[WIRE] params.common.remove_host:", human_depletion, "(from human_depletion =", isTRUE(params$human_depletion), ")\n")

  # --- minimap2 human genome index auto-detection ---
  # Not a UI control - auto-detected from filesystem.
  # Config: config$tools$minimap2$human_mmi + config$tools$minimap2$split_prefix
  # Pipeline reads: .tools.minimap2.human_mmi (sr_meta.sh, run_in_container.sh)
  # Matches WIZARD_REFERENCE_INDEXES naming (all 4 strategies, priority order).
  # split_prefix: 1 for split indexes, 0 for standard/lowmem (matches CLI runner.py)
  repo_root_sr_meta <- dirname(getwd())
  grch38_dir_sr     <- file.path(repo_root_sr_meta, "main", "data", "reference", "human", "grch38")
  mmi_candidates_sr <- list(
    list(name = "GRCh38.primary_assembly.genome.mmi",         split = 0L),
    list(name = "GRCh38.primary_assembly.genome.lowmem.mmi",  split = 0L),
    list(name = "GRCh38.primary_assembly.genome.split2G.mmi", split = 1L),
    list(name = "GRCh38.primary_assembly.genome.split4G.mmi", split = 1L)
  )
  human_mmi_path    <- ""
  minimap2_split_sr <- 0L
  for (cand in mmi_candidates_sr) {
    p <- file.path(grch38_dir_sr, cand$name)
    if (file.exists(p)) {
      human_mmi_path    <- p
      minimap2_split_sr <- cand$split
      cat("[WIRE] tools.minimap2.human_mmi: auto-detected at", p, "\n")
      cat("[WIRE] tools.minimap2.split_prefix:", minimap2_split_sr, "\n")
      break
    }
  }
  if (human_mmi_path == "") {
    cat("[WIRE] tools.minimap2.human_mmi: NOT FOUND - run Setup Wizard to build minimap2 index\n")
    if (human_depletion == 1L) {
      cat("[WIRE] WARNING: human_depletion=1 but no minimap2 index found - pipeline will fail\n")
    }
  }

  # --- VALENCIA centroids auto-detection (vaginal specimens only) ---
  # Mirrors generate_sr_amp_config VALENCIA handling exactly.
  # Pipeline reads: .valencia.enabled, .valencia.centroids_csv (sr_meta.sh)
  valencia_centroids_candidates_sr <- c(
    file.path(repo_root_sr_meta, "tools", "VALENCIA", "CST_centroids_012920.csv"),
    file.path(repo_root_sr_meta, "main", "tools", "VALENCIA", "CST_centroids_012920.csv")
  )
  valencia_centroids_path_sr <- ""
  for (candidate in valencia_centroids_candidates_sr) {
    if (file.exists(candidate)) {
      valencia_centroids_path_sr <- candidate
      cat("[WIRE] valencia.centroids_csv: auto-detected at", valencia_centroids_path_sr, "\n")
      break
    }
  }
  if (valencia_centroids_path_sr == "") {
    cat("[WIRE] valencia.centroids_csv: NOT FOUND - using default path\n")
    valencia_centroids_path_sr <- file.path(repo_root_sr_meta, "tools", "VALENCIA", "CST_centroids_012920.csv")
  }
  valencia_enabled_sr <- if (specimen == "vaginal" &&
                              !is.null(params$valencia) && params$valencia == "yes") 1L else 0L
  cat("[WIRE] valencia.enabled:", valencia_enabled_sr, "\n")

  # --- postprocess enabled ---
  # UI: checkboxInput("enable_postprocess") default=TRUE
  # Config: config$postprocess$enabled (integer: 1 or 0)
  # CRITICAL: backend checks postprocess.enabled == 1 (integer, not boolean)
  postprocess_enabled <- if (!is.null(params$enable_postprocess) && isTRUE(params$enable_postprocess)) 1L else 0L
  cat("[WIRE] postprocess.enabled:", postprocess_enabled, "(from enable_postprocess =", isTRUE(params$enable_postprocess), ")\n")

  # --- postprocess steps ---
  # Key name mapping (UI value in output_selected -> backend postprocess.steps key):
  #   "heatmap"     -> steps$heatmap
  #   "pie_chart"   -> steps$piechart     (backend uses no underscore)
  #   "stacked_bar" -> steps$stacked_bar
  #   "raw_csv"     -> steps$results_csv  (different name in backend)
  postprocess_steps <- list(
    heatmap            = pp_step("heatmap",     output_selected, postprocess_enabled),
    piechart           = pp_step("pie_chart",   output_selected, postprocess_enabled),
    stacked_bar        = pp_step("stacked_bar", output_selected, postprocess_enabled),
    results_csv        = postprocess_enabled,  # always on — tables always generated
    relative_abundance = 0L,
    valencia           = if (postprocess_enabled == 1L && valencia_enabled_sr == 1L) 1L else 0L
  )
  cat("[WIRE] postprocess.steps.heatmap:", postprocess_steps$heatmap, "\n")
  cat("[WIRE] postprocess.steps.piechart:", postprocess_steps$piechart, "(from 'pie_chart' in output_selected)\n")
  cat("[WIRE] postprocess.steps.stacked_bar:", postprocess_steps$stacked_bar, "\n")
  cat("[WIRE] postprocess.steps.results_csv:", postprocess_steps$results_csv, "(always on)\n")

  # --- build params.common ---
  params_common <- list(
    min_qscore  = quality_threshold,
    remove_host = human_depletion,
    specimen    = specimen
  )
  if (!is.null(min_read_length)) params_common$min_read_length <- min_read_length
  if (!is.null(trim_adapter))    params_common$trim_adapter <- trim_adapter
  if (!is.null(demultiplex))     params_common$demultiplex  <- demultiplex

  # --- assemble config ---
  config <- list(
    pipeline_id = "sr_meta",

    run = list(
      work_dir        = params$output_dir,
      run_id          = params$run_id,
      force_overwrite = 1L
    ),

    technology = unname(technology),
    specimen   = specimen,

    input = input_obj,

    resources = list(
      threads = threads
    ),

    params = list(
      common = params_common
    ),

    output = list(
      selected = output_selected
    ),

    # postprocess: ALWAYS written; backend reads postprocess.enabled AND postprocess.steps.*
    postprocess = list(
      enabled = postprocess_enabled,
      steps   = postprocess_steps
    )
  )

  # --- run scope (conditional) ---
  if (!is.null(run_scope)) {
    config$run$scope <- run_scope
  }

  # --- kraken2 DB path ---
  # UI: textInput("kraken_db") (shown when pipeline == "sr_meta")
  # Fallback: textInput("external_db_dir") with selectInput("database_type")
  # Config: config$host$resources$kraken2_db$host_path
  kraken_db_path <- NULL
  if (!is.null(params$kraken_db) && nchar(trimws(params$kraken_db)) > 0) {
    kraken_db_path <- trimws(params$kraken_db)
    cat("[WIRE] host.resources.kraken2_db.host_path:", kraken_db_path, "(from kraken_db field)\n")
  } else if (!is.null(params$external_db_dir) && nchar(trimws(params$external_db_dir)) > 0) {
    db_type <- params$database_type %||% "auto"
    if (db_type %in% c("auto", "kraken2")) {
      kraken_db_path <- trimws(params$external_db_dir)
      cat("[WIRE] host.resources.kraken2_db.host_path:", kraken_db_path, "(from external_db_dir, type:", db_type, ")\n")
    }
  }

  if (!is.null(kraken_db_path)) {
    config$host <- list(
      resources = list(
        kraken2_db = list(
          host_path = kraken_db_path
        )
      )
    )
  }

  # --- Kraken2 classification params (confidence / minimum hit groups) ---
  # CLI reads: .tools.kraken2.vaginal.confidence, .tools.kraken2.vaginal.minimum_hit_groups
  #            .tools.kraken2.nonvaginal.confidence, .tools.kraken2.nonvaginal.minimum_hit_groups
  kraken_confidence     <- if (!is.null(params$kraken_confidence))     as.numeric(params$kraken_confidence)     else NULL
  kraken_min_hit_groups <- if (!is.null(params$kraken_min_hit_groups)) as.integer(params$kraken_min_hit_groups) else NULL
  cat("[WIRE] tools.kraken2.*.confidence:", if (is.null(kraken_confidence)) "(default)" else kraken_confidence, "\n")
  cat("[WIRE] tools.kraken2.*.minimum_hit_groups:", if (is.null(kraken_min_hit_groups)) "(default)" else kraken_min_hit_groups, "\n")
  if (!is.null(kraken_confidence) || !is.null(kraken_min_hit_groups)) {
    kp <- list()
    if (!is.null(kraken_confidence))     kp$confidence         <- kraken_confidence
    if (!is.null(kraken_min_hit_groups)) kp$minimum_hit_groups <- kraken_min_hit_groups
    if (is.null(config$tools)) config$tools <- list()
    config$tools$kraken2 <- list(vaginal = kp, nonvaginal = kp)
  }

  # --- Bracken readlen: respect user wizard preference, auto-detect from DB, fallback to 150 (SR PE150 reads) ---
  # CLI reads: .tools.bracken.vaginal.enabled/.readlen, .tools.bracken.nonvaginal.enabled/.readlen
  bracken_rl_pref_sr <- params$bracken_readlen %||% "auto"
  bracken_readlen_sr <- if (bracken_rl_pref_sr == "auto") {
    available_sr <- if (!is.null(kraken_db_path) && dir.exists(kraken_db_path)) {
      files_sr <- list.files(kraken_db_path, pattern = "^database[0-9]+mers\\.kmer_distrib$")
      lens_sr  <- suppressWarnings(
        as.integer(gsub("^database([0-9]+)mers\\.kmer_distrib$", "\\1", files_sr)))
      lens_sr[!is.na(lens_sr)]
    } else integer(0)
    if (length(available_sr) > 0) {
      # SR reads are short (~PE150); unlike LR (which prefers the longest available
      # profile), pick whichever profile is CLOSEST to 150bp. A DB built for both LR
      # and SR use (e.g. one with 150/500/750/.../2000mers profiles) must not hand SR
      # runs a badly-mismatched long-read profile just because it's the largest.
      chosen_sr <- available_sr[which.min(abs(available_sr - 150L))]
      cat("[WIRE] bracken readlen: auto-detected", chosen_sr, "mers from DB (closest to 150bp SR read length)\n")
      chosen_sr
    } else {
      cat("[WIRE] bracken readlen: auto fallback to 150 (no DB path or no kmer_distrib)\n")
      150L
    }
  } else {
    rl_sr <- suppressWarnings(as.integer(bracken_rl_pref_sr))
    cat("[WIRE] bracken readlen: user preference", rl_sr, "mers\n")
    rl_sr
  }
  if (is.null(config$tools)) config$tools <- list()
  config$tools$bracken <- list(
    vaginal    = list(enabled = 1L, readlen = bracken_readlen_sr),
    nonvaginal = list(enabled = 1L, readlen = bracken_readlen_sr)
  )

  # --- Kraken2 memory mapping (low-RAM mode) ---
  # CLI reads: .params.kraken2.memory_mapping (sr_meta.sh)
  kraken_memory_mapping <- if (!is.null(params$kraken_memory_mapping) && isTRUE(params$kraken_memory_mapping)) TRUE else FALSE
  cat("[WIRE] params.kraken2.memory_mapping:", kraken_memory_mapping, "\n")
  if (kraken_memory_mapping) {
    config$params$kraken2 <- list(memory_mapping = TRUE)
  }

  # --- minimap2 index (always output when found, pipeline ignores if remove_host=0) ---
  # Pipeline reads: .tools.minimap2.human_mmi (sr_meta.sh, run_in_container.sh)
  #                 .tools.minimap2.split_prefix (sr_meta.sh)
  if (human_mmi_path != "") {
    if (is.null(config$tools)) config$tools <- list()
    config$tools$minimap2 <- list(
      human_mmi    = human_mmi_path,
      split_prefix = minimap2_split_sr
    )
  }

  # --- VALENCIA (conditional: vaginal only) ---
  # Pipeline reads: .valencia.enabled, .valencia.centroids_csv (sr_meta.sh)
  if (specimen == "vaginal") {
    config$valencia <- list(
      enabled       = valencia_enabled_sr,
      mode          = "auto",
      centroids_csv = valencia_centroids_path_sr
    )
    cat("[WIRE] valencia.enabled:", valencia_enabled_sr, "| centroids_csv:", valencia_centroids_path_sr, "\n")
    config$postprocess$steps$valencia <- if (postprocess_enabled == 1L && valencia_enabled_sr == 1L) 1L else 0L
    cat("[WIRE] postprocess.steps.valencia:", config$postprocess$steps$valencia, "\n")
  } else {
    cat("[WIRE] valencia: omitted (specimen is", specimen, "not vaginal)\n")
    config$postprocess$steps$valencia <- 0L
  }

  # --- sample_map (barcode → sample name) ---
  sample_map <- if (!is.null(params$sample_map) && length(params$sample_map) > 0) {
    params$sample_map
  } else NULL

  if (!is.null(sample_map)) {
    config$sample_map   <- sample_map
    sample_sheet_path   <- file.path(params$output_dir, params$run_id, "sample_sheet.tsv")
    config$sample_sheet <- sample_sheet_path

    for (sn in c("heatmap", "piechart", "stacked_bar", "results_csv")) {
      current_val <- config$postprocess$steps[[sn]]
      if (!is.null(current_val) && identical(current_val, 1L)) {
        config$postprocess$steps[[sn]] <- list(
          enabled = 1L,
          params  = list(sample_sheet = sample_sheet_path)
        )
      }
    }
    cat("[WIRE] sample_map:", length(sample_map), "entries\n")
    cat("[WIRE] sample_sheet:", sample_sheet_path, "\n")
  }

  # --- pre-return audit ---
  cat("\n[AUDIT] sr_meta config field check:\n")
  cat("  pipeline_id:                        ", config$pipeline_id, "\n")
  cat("  run.work_dir:                       ", config$run$work_dir, "\n")
  cat("  run.run_id:                         ", config$run$run_id, "\n")
  cat("  run.scope:                          ", if (!is.null(config$run$scope)) config$run$scope else "(none)", "\n")
  cat("  technology:                         ", config$technology, "\n")
  cat("  specimen:                           ", config$specimen, "\n")
  cat("  input.style:                        ", config$input$style, "\n")
  cat("  resources.threads:                  ", config$resources$threads, "\n")
  cat("  params.common.min_qscore:           ", config$params$common$min_qscore, "\n")
  cat("  params.common.min_read_length:      ", if (!is.null(config$params$common$min_read_length)) config$params$common$min_read_length else "(omitted)", "\n")
  cat("  params.common.trim_adapter:         ", if (!is.null(config$params$common$trim_adapter)) config$params$common$trim_adapter else "(omitted)", "\n")
  cat("  params.common.demultiplex:          ", if (!is.null(config$params$common$demultiplex)) config$params$common$demultiplex else "(omitted)", "\n")
  cat("  params.common.remove_host:          ", config$params$common$remove_host, "\n")
  cat("  output.selected:                    ", paste(config$output$selected, collapse=", "), "\n")
  cat("  postprocess.enabled:                ", config$postprocess$enabled, "[TYPE:", class(config$postprocess$enabled), "]\n")
  cat("  postprocess.steps.heatmap:          ", .fmt_step(config$postprocess$steps$heatmap), "\n")
  cat("  postprocess.steps.piechart:         ", .fmt_step(config$postprocess$steps$piechart), "\n")
  cat("  postprocess.steps.stacked_bar:      ", .fmt_step(config$postprocess$steps$stacked_bar), "\n")
  cat("  postprocess.steps.results_csv:      ", .fmt_step(config$postprocess$steps$results_csv), "\n")
  cat("  postprocess.steps.relative_abundance:", config$postprocess$steps$relative_abundance, "\n")
  if (!is.null(config$host$resources$kraken2_db)) {
    cat("  host.resources.kraken2_db:          ", config$host$resources$kraken2_db$host_path, "\n")
  }
  cat("  tools.kraken2.vaginal.confidence:   ", if (!is.null(config$tools$kraken2$vaginal$confidence)) config$tools$kraken2$vaginal$confidence else "(default)", "\n")
  cat("  tools.kraken2.vaginal.min_hit_groups:", if (!is.null(config$tools$kraken2$vaginal$minimum_hit_groups)) config$tools$kraken2$vaginal$minimum_hit_groups else "(default)", "\n")
  cat("  tools.bracken.vaginal.readlen:      ", if (!is.null(config$tools$bracken$vaginal$readlen)) config$tools$bracken$vaginal$readlen else "(not set)", "\n")
  cat("  params.kraken2.memory_mapping:      ", if (!is.null(config$params$kraken2$memory_mapping)) config$params$kraken2$memory_mapping else "FALSE (omitted)", "\n")
  cat("  tools.minimap2.human_mmi:           ", if (!is.null(config$tools$minimap2$human_mmi)) config$tools$minimap2$human_mmi else "(not set)", "\n")
  cat("  postprocess.steps.valencia:         ", config$postprocess$steps$valencia, "\n")
  if (!is.null(config$valencia)) {
    cat("  valencia.enabled:                   ", config$valencia$enabled, "\n")
    cat("  valencia.centroids_csv:             ", config$valencia$centroids_csv, "\n")
  }
  cat("========== SR_META CONFIG COMPLETE ==========\n\n")

  config
}

generate_lr_amp_config <- function(params) {
  cat("\n========== BUILDING LR_AMP CONFIG ==========\n")

  # --- technology ---
  tech_map <- c("ont" = "ONT", "pacbio" = "PACBIO")
  technology <- tech_map[params$technology] %||% "ONT"
  cat("[WIRE] technology:", params$technology, "->", unname(technology), "\n")

  # --- input style + file ---
  input_format <- params$input_format %||% "fastq"
  input_style <- switch(input_format,
    "fastq" = "FASTQ_SINGLE",
    "fast5" = "FAST5_DIR",
    "pod5"  = "FAST5_DIR",
    "FASTQ_SINGLE"
  )
  cat("[WIRE] input_format:", input_format, "-> input.style:", input_style, "\n")

  input_obj <- list(style = input_style)
  if (input_style == "FASTQ_SINGLE") {
    input_obj$fastq <- trimws(params$input_path)
    cat("[WIRE] input.fastq:", trimws(params$input_path), "\n")
  } else {
    # FAST5_DIR or POD5_DIR - ensure we have a directory, not a file
    fast5_path <- trimws(params$input_path)
    if (file.exists(fast5_path) && !dir.exists(fast5_path)) {
      # User selected a file instead of directory - use parent directory
      fast5_path <- dirname(fast5_path)
      cat("[WIRE] Detected file instead of directory, using parent:", fast5_path, "\n")
    }
    input_obj$fast5_dir <- fast5_path
    cat("[WIRE] input.fast5_dir:", fast5_path, "\n")
  }

  # --- threads ---
  threads <- as.integer(params$threads %||% 4L)
  cat("[WIRE] resources.threads:", threads, "\n")

  # --- quality threshold ---
  # LR backend reads from tools.qfilter.min_q (NOT params.common.min_qscore)
  quality_threshold <- as.integer(params$quality_threshold %||% 7L)
  cat("[WIRE] tools.qfilter.min_q:", quality_threshold, "\n")

  # --- min read length ---
  # LR backend reads from tools.qfilter.min_len
  min_read_length <- if (!is.null(params$min_read_length)) as.integer(params$min_read_length) else NULL
  cat("[WIRE] tools.qfilter.min_len:", if (is.null(min_read_length)) "(omitted)" else min_read_length, "\n")

  # --- specimen ---
  specimen <- params$sample_type %||% "other"
  cat("[WIRE] specimen:", specimen, "\n")

  # --- run scope ---
  run_scope <- params$run_scope %||% NULL
  cat("[WIRE] run.scope:", if (is.null(run_scope)) "(omitted)" else run_scope, "\n")

  # --- trim adapter ---
  trim_adapter <- if (!is.null(params$trim_adapter)) as.logical(params$trim_adapter) else NULL
  cat("[WIRE] params.common.trim_adapter:", if (is.null(trim_adapter)) "(omitted)" else trim_adapter, "\n")

  # --- demultiplex ---
  demultiplex <- if (!is.null(params$demultiplex)) as.logical(params$demultiplex) else NULL
  cat("[WIRE] params.common.demultiplex:", if (is.null(demultiplex)) "(omitted)" else demultiplex, "\n")

  # --- primer sequences ---
  # Parse newline-separated string into forward/reverse
  primer_forward <- NULL
  primer_reverse <- NULL
  if (!is.null(params$primer_sequences) && nchar(trimws(params$primer_sequences)) > 0) {
    primer_lines <- strsplit(params$primer_sequences, "\n")[[1]]
    primer_lines <- trimws(primer_lines[nchar(trimws(primer_lines)) > 0])
    if (length(primer_lines) >= 1) primer_forward <- primer_lines[1]
    if (length(primer_lines) >= 2) primer_reverse <- primer_lines[2]
    cat("[WIRE] params.primers.forward:", primer_forward %||% "(none)", "\n")
    cat("[WIRE] params.primers.reverse:", primer_reverse %||% "(none)", "\n")
  } else {
    cat("[WIRE] params.primers: (omitted)\n")
  }

  # --- barcode sequences ---
  barcode_sequences <- NULL
  if (!is.null(params$barcode_sequences) && nchar(trimws(params$barcode_sequences)) > 0) {
    barcode_lines <- strsplit(params$barcode_sequences, "\n")[[1]]
    barcode_lines <- trimws(barcode_lines[nchar(trimws(barcode_lines)) > 0])
    if (length(barcode_lines) > 0) {
      barcode_sequences <- barcode_lines
      cat("[WIRE] input.barcodes.sequences:", length(barcode_lines), "entries\n")
    }
  }

  # --- barcoding_kit and ligation_kit ---
  # For FAST5/POD5: go in tools.dorado.barcode_kit / tools.dorado.ligation_kit
  # For FASTQ: go in tools.barcoding_kit / tools.ligation_kit
  barcoding_kit <- if (!is.null(params$barcoding_kit) && nchar(trimws(params$barcoding_kit)) > 0) trimws(params$barcoding_kit) else NULL
  ligation_kit  <- if (!is.null(params$ligation_kit)  && nchar(trimws(params$ligation_kit))  > 0) trimws(params$ligation_kit)  else NULL
  cat("[WIRE] barcoding_kit:", if (is.null(barcoding_kit)) "(omitted)" else barcoding_kit, "\n")
  cat("[WIRE] ligation_kit:",  if (is.null(ligation_kit))  "(omitted)" else ligation_kit,  "\n")

  # --- output selected ---
  output_selected <- if (!is.null(params$output_selected) && length(params$output_selected) > 0) {
    as.character(params$output_selected)
  } else {
    c("all")
  }
  cat("[WIRE] output.selected:", paste(output_selected, collapse=", "), "\n")

  # --- postprocess enabled ---
  postprocess_enabled <- if (!is.null(params$enable_postprocess) && isTRUE(params$enable_postprocess)) 1L else 0L
  cat("[WIRE] postprocess.enabled:", postprocess_enabled, "\n")

  # --- classifier: always Emu for lr_amp ---
  full_length <- 1L
  cat("[WIRE] params.full_length: 1 (Emu, full-length 16S - lr_amp always uses Emu)\n")

  # --- VALENCIA auto-detect ---
  repo_root <- dirname(getwd())
  valencia_centroids_candidates <- c(
    file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv"),
    file.path(repo_root, "main", "tools", "VALENCIA", "CST_centroids_012920.csv")
  )
  valencia_centroids_path <- ""
  for (candidate in valencia_centroids_candidates) {
    if (file.exists(candidate)) {
      valencia_centroids_path <- candidate
      cat("[WIRE] valencia.centroids_csv: auto-detected at", valencia_centroids_path, "\n")
      break
    }
  }
  if (valencia_centroids_path == "") {
    valencia_centroids_path <- file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv")
    cat("[WIRE] valencia.centroids_csv: NOT FOUND - using default path\n")
  }

  # --- build params.common ---
  params_common <- list(
    min_qscore  = quality_threshold,
    remove_host = 0L,
    specimen    = specimen
  )
  if (!is.null(trim_adapter)) params_common$trim_adapter <- trim_adapter
  if (!is.null(demultiplex))  params_common$demultiplex  <- demultiplex

  # --- Emu database and binary auto-detection ---
  # LR_AMP requires Emu database for taxonomic classification
  # Pipeline script reads from config$tools$emu$db and config$tools$emu$bin
  emu_db_path <- file.path(repo_root, "main", "data", "reference", "emu")
  if (file.exists(emu_db_path)) {
    cat("[WIRE] tools.emu.db: auto-detected at", emu_db_path, "\n")
  } else {
    emu_db_path <- ""
    cat("[WIRE] tools.emu.db: NOT FOUND - Emu classification will be skipped\n")
  }

  # Emu binary (Python script in container)
  # In Docker container, this is at /work/pipelines/patches/emu_v3.5.5_patched.py
  emu_bin_path <- "/work/pipelines/patches/emu_v3.5.5_patched.py"
  cat("[WIRE] tools.emu.bin:", emu_bin_path, "(Python script in container)\n")

  # --- build tools block ---
  tools_obj <- list(
    qfilter = list(enabled = 1L, min_q = quality_threshold)
  )
  if (!is.null(min_read_length)) {
    tools_obj$qfilter$min_len <- min_read_length
  }

  # Add Emu database path and binary
  if (emu_db_path != "") {
    tools_obj$emu <- list(
      db = emu_db_path,
      bin = emu_bin_path
    )
  }
  if (!is.null(params$emu_min_pid)) {
    tools_obj$emu$min_pid <- as.numeric(params$emu_min_pid)
  }

  # Dorado settings (FAST5/POD5 only)
  if (input_format %in% c("fast5", "pod5")) {
    dorado_obj <- list()

    # Auto-detect Dorado binary for Docker (Linux version at tools/dorado/)
    # Wizard downloads Linux version to tools/dorado/ for use inside Docker container
    dorado_bin_host <- file.path(repo_root, "tools", "dorado", "bin", "dorado")

    if (!file.exists(dorado_bin_host)) {
      # Check for version-specific installations (e.g., dorado-0.9.6)
      tools_dir <- file.path(repo_root, "tools")
      dorado_dirs <- list.dirs(tools_dir, full.names = TRUE, recursive = FALSE)
      dorado_dirs <- dorado_dirs[grepl("^dorado-[0-9]", basename(dorado_dirs))]
      dorado_dirs <- dorado_dirs[!grepl("-host$", basename(dorado_dirs))]  # Skip macOS host binaries

      if (length(dorado_dirs) > 0) {
        # Use the first (or newest) version found
        dorado_dirs <- sort(dorado_dirs, decreasing = TRUE)
        dorado_bin_host <- file.path(dorado_dirs[1], "bin", "dorado")
      }
    }

    # Binary path — tools/ is at the repo root, which is OUTSIDE main/.
    # Docker mounts main/ at /work, so /work/tools/ does NOT exist.
    # run_in_container.sh also mounts /Users:/Users (macOS) and REPO_ROOT:REPO_ROOT,
    # so the host absolute path of the binary is directly accessible inside the container.
    if (file.exists(dorado_bin_host)) {
      dorado_obj$bin       <- dorado_bin_host   # tools.dorado.bin  (nested, legacy)
      tools_obj$dorado_bin <- dorado_bin_host   # tools.dorado_bin  (flat — what lr_amp.sh reads)
      cat("[WIRE] tools.dorado_bin:", dorado_bin_host, "\n")
    } else {
      cat("[WIRE] WARNING: Dorado Linux binary not found under tools/\n")
      cat("[WIRE] Run Setup Wizard to download Dorado for Docker\n")
    }

    # Model: Use NAME ONLY like CLI does - script will combine with models directory
    dorado_model <- if (!is.null(params$dorado_model) && nchar(trimws(params$dorado_model)) > 0) {
      trimws(params$dorado_model)
    } else {
      # Auto-detect: prefer v3.5.2 if installed (for 4kHz data), else v5.2.0
      models_dir_host <- file.path(repo_root, "tools", "models", "dorado")
      v352_name <- "dna_r10.4.1_e8.2_400bps_hac@v3.5.2"
      v420_name <- "dna_r10.4.1_e8.2_400bps_hac@v4.2.0"
      v520_name <- "dna_r10.4.1_e8.2_400bps_hac@v5.2.0"

      v352_path <- file.path(models_dir_host, v352_name)
      v420_path <- file.path(models_dir_host, v420_name)
      v520_path <- file.path(models_dir_host, v520_name)

      if (dir.exists(v352_path)) {
        cat("[WIRE] Auto-detected v3.5.2 model for 4kHz data\n")
        v352_name
      } else if (dir.exists(v420_path)) {
        cat("[WIRE] Auto-detected v4.2.0 model\n")
        v420_name
      } else if (dir.exists(v520_path)) {
        cat("[WIRE] Auto-detected v5.2.0 model\n")
        v520_name
      } else {
        cat("[WIRE] No models found, defaulting to v5.2.0 (will download on demand)\n")
        v520_name
      }
    }
    dorado_obj$model <- dorado_model
    cat("[WIRE] tools.dorado.model:", dorado_model, "\n")

    # Barcoding/ligation kit go inside dorado block for FAST5/POD5
    if (!is.null(barcoding_kit)) dorado_obj$barcode_kit   <- barcoding_kit
    if (!is.null(ligation_kit)) {
      dorado_obj$ligation_kit   <- ligation_kit
      dorado_obj$sequencing_kit <- ligation_kit  # Dorado 0.9.6 requires --sequencing-kit for trim
      cat("[WIRE] tools.dorado.sequencing_kit:", ligation_kit, "(copied from ligation_kit)\n")
    }
    if (length(dorado_obj) > 0) tools_obj$dorado <- dorado_obj
  } else {
    # FASTQ: kit values go in top-level tools block
    if (!is.null(barcoding_kit)) tools_obj$barcoding_kit <- barcoding_kit
    if (!is.null(ligation_kit))  tools_obj$ligation_kit  <- ligation_kit
  }

  # --- assemble config ---
  config <- list(
    pipeline_id = "lr_amp",

    run = list(
      work_dir        = params$output_dir,
      run_id          = params$run_id,
      force_overwrite = 1L
    ),

    technology = unname(technology),
    specimen   = specimen,

    input = input_obj,

    resources = list(threads = threads),

    params = list(
      common      = params_common,
      full_length = full_length,
      seq_type    = if (technology == "ONT") "map-ont" else "map-pb"
    ),

    tools = tools_obj,

    output = list(selected = output_selected),

    postprocess = list(
      enabled = postprocess_enabled,
      steps = list(
        heatmap            = pp_step("heatmap",     output_selected, postprocess_enabled),
        piechart           = pp_step("pie_chart",   output_selected, postprocess_enabled),
        stacked_bar        = pp_step("stacked_bar", output_selected, postprocess_enabled),
        results_csv        = postprocess_enabled,  # always on — tables always generated
        relative_abundance = 0L,
        valencia           = 0L  # updated below for vaginal
      )
    )
  )

  # --- run scope (conditional) ---
  if (!is.null(run_scope)) config$run$scope <- run_scope

  # --- primer sequences (conditional) ---
  if (!is.null(primer_forward) || !is.null(primer_reverse)) {
    primers_obj <- list()
    if (!is.null(primer_forward)) primers_obj$forward <- primer_forward
    if (!is.null(primer_reverse)) primers_obj$reverse <- primer_reverse
    config$params$primers <- primers_obj
  }

  # --- barcode sequences (conditional) ---
  if (!is.null(barcode_sequences)) {
    config$input$barcodes <- list(sequences = barcode_sequences)
  }

  # --- VALENCIA (conditional: vaginal only) ---
  if (specimen == "vaginal") {
    valencia_enabled <- if (!is.null(params$valencia) && params$valencia == "yes") 1L else 0L
    config$valencia <- list(
      enabled       = valencia_enabled,
      mode          = "auto",
      centroids_csv = valencia_centroids_path
    )
    cat("[WIRE] valencia.enabled:", valencia_enabled, "| centroids_csv:", valencia_centroids_path, "\n")
    config$postprocess$steps$valencia <- if (postprocess_enabled == 1L && valencia_enabled == 1L) 1L else 0L
    cat("[WIRE] postprocess.steps.valencia:", config$postprocess$steps$valencia, "\n")
  } else {
    cat("[WIRE] valencia: omitted (specimen is", specimen, "not vaginal)\n")
    config$postprocess$steps$valencia <- 0L
  }

  # --- sample_map (barcode → sample name) ---
  sample_map <- if (!is.null(params$sample_map) && length(params$sample_map) > 0) {
    params$sample_map
  } else NULL

  if (!is.null(sample_map)) {
    config$sample_map   <- sample_map
    sample_sheet_path   <- file.path(params$output_dir, params$run_id, "sample_sheet.tsv")
    config$sample_sheet <- sample_sheet_path

    # Embed sample_sheet path in each enabled postprocess step so R scripts receive it
    for (sn in c("heatmap", "piechart", "stacked_bar", "results_csv")) {
      current_val <- config$postprocess$steps[[sn]]
      if (!is.null(current_val) && identical(current_val, 1L)) {
        config$postprocess$steps[[sn]] <- list(
          enabled = 1L,
          params  = list(sample_sheet = sample_sheet_path)
        )
      }
    }
    cat("[WIRE] sample_map:", length(sample_map), "entries\n")
    cat("[WIRE] sample_sheet:", sample_sheet_path, "\n")
  }

  # --- pre-return audit ---
  cat("\n[AUDIT] lr_amp config field check:\n")
  cat("  pipeline_id:                   ", config$pipeline_id, "\n")
  cat("  run.work_dir:                  ", config$run$work_dir, "\n")
  cat("  run.run_id:                    ", config$run$run_id, "\n")
  cat("  run.scope:                     ", if (!is.null(config$run$scope)) config$run$scope else "(none)", "\n")
  cat("  technology:                    ", config$technology, "\n")
  cat("  specimen:                      ", config$specimen, "\n")
  cat("  input.style:                   ", config$input$style, "\n")
  cat("  resources.threads:             ", config$resources$threads, "\n")
  cat("  params.common.trim_adapter:    ", if (!is.null(config$params$common$trim_adapter)) config$params$common$trim_adapter else "(omitted)", "\n")
  cat("  params.common.demultiplex:     ", if (!is.null(config$params$common$demultiplex)) config$params$common$demultiplex else "(omitted)", "\n")
  cat("  params.full_length:            ", config$params$full_length, "\n")
  cat("  params.seq_type:               ", config$params$seq_type, "\n")
  cat("  tools.qfilter.min_q:           ", config$tools$qfilter$min_q, "\n")
  cat("  tools.qfilter.min_len:         ", if (!is.null(config$tools$qfilter$min_len)) config$tools$qfilter$min_len else "(omitted)", "\n")
  cat("  tools.emu.db:                  ", if (!is.null(config$tools$emu$db)) config$tools$emu$db else "(not set - classification will be skipped)", "\n")
  cat("  tools.emu.bin:                 ", if (!is.null(config$tools$emu$bin)) config$tools$emu$bin else "(not set)", "\n")
  cat("  output.selected:               ", paste(config$output$selected, collapse=", "), "\n")
  cat("  postprocess.enabled:           ", config$postprocess$enabled, "\n")
  cat("  postprocess.steps.heatmap:     ", .fmt_step(config$postprocess$steps$heatmap), "\n")
  cat("  postprocess.steps.piechart:    ", .fmt_step(config$postprocess$steps$piechart), "\n")
  cat("  postprocess.steps.stacked_bar: ", .fmt_step(config$postprocess$steps$stacked_bar), "\n")
  cat("  postprocess.steps.results_csv: ", .fmt_step(config$postprocess$steps$results_csv), "(always on)\n")
  cat("  postprocess.steps.valencia:    ", config$postprocess$steps$valencia, "\n")
  if (!is.null(config$valencia)) cat("  valencia.enabled:              ", config$valencia$enabled, "\n")
  if (!is.null(config$tools$dorado)) {
    cat("  tools.dorado.barcode_kit:      ", config$tools$dorado$barcode_kit %||% "(none)", "\n")
    cat("  tools.dorado.ligation_kit:     ", config$tools$dorado$ligation_kit %||% "(none)", "\n")
    cat("  tools.dorado.sequencing_kit:   ", config$tools$dorado$sequencing_kit %||% "(none)", "\n")
  }
  cat("========== LR_AMP CONFIG COMPLETE ==========\n\n")

  config
}

generate_lr_meta_config <- function(params) {
  cat("\n========== BUILDING LR_META CONFIG ==========\n")

  # --- technology ---
  tech_map <- c("ont" = "ONT", "pacbio" = "PACBIO")
  technology <- tech_map[params$technology] %||% "ONT"
  cat("[WIRE] technology:", params$technology, "->", unname(technology), "\n")

  # --- input style + file ---
  input_format <- params$input_format %||% "fastq"
  input_style <- switch(input_format,
    "fastq" = "FASTQ_SINGLE",
    "fast5" = "FAST5_DIR",
    "pod5"  = "FAST5_DIR",
    "FASTQ_SINGLE"
  )
  cat("[WIRE] input_format:", input_format, "-> input.style:", input_style, "\n")

  input_obj <- list(style = input_style)
  if (input_style == "FASTQ_SINGLE") {
    input_obj$fastq <- trimws(params$input_path)
    cat("[WIRE] input.fastq:", trimws(params$input_path), "\n")
  } else {
    # FAST5_DIR or POD5_DIR - ensure we have a directory, not a file
    fast5_path <- trimws(params$input_path)
    if (file.exists(fast5_path) && !dir.exists(fast5_path)) {
      # User selected a file instead of directory - use parent directory
      fast5_path <- dirname(fast5_path)
      cat("[WIRE] Detected file instead of directory, using parent:", fast5_path, "\n")
    }
    input_obj$fast5_dir <- fast5_path
    cat("[WIRE] input.fast5_dir:", fast5_path, "\n")
  }

  # --- threads ---
  threads <- as.integer(params$threads %||% 4L)
  cat("[WIRE] resources.threads:", threads, "\n")

  # --- quality threshold ---
  # LR backend reads from tools.qfilter.min_q
  quality_threshold <- as.integer(params$quality_threshold %||% 7L)
  cat("[WIRE] tools.qfilter.min_q:", quality_threshold, "\n")

  # --- min read length ---
  # 0 means "no filter" — omit the field entirely so the CLI uses its own default
  min_read_length <- if (!is.null(params$min_read_length) && as.integer(params$min_read_length) > 0L) as.integer(params$min_read_length) else NULL
  cat("[WIRE] tools.qfilter.min_len:", if (is.null(min_read_length)) "(omitted — no filter)" else min_read_length, "\n")

  # --- specimen ---
  specimen <- params$sample_type %||% "other"
  cat("[WIRE] specimen:", specimen, "\n")

  # --- run scope ---
  run_scope <- params$run_scope %||% NULL
  cat("[WIRE] run.scope:", if (is.null(run_scope)) "(omitted)" else run_scope, "\n")

  # --- trim adapter ---
  trim_adapter <- if (!is.null(params$trim_adapter)) as.logical(params$trim_adapter) else NULL
  cat("[WIRE] params.common.trim_adapter:", if (is.null(trim_adapter)) "(omitted)" else trim_adapter, "\n")

  # --- demultiplex ---
  demultiplex <- if (!is.null(params$demultiplex)) as.logical(params$demultiplex) else NULL
  cat("[WIRE] params.common.demultiplex:", if (is.null(demultiplex)) "(omitted)" else demultiplex, "\n")

  # --- primer sequences ---
  primer_forward <- NULL
  primer_reverse <- NULL
  if (!is.null(params$primer_sequences) && nchar(trimws(params$primer_sequences)) > 0) {
    primer_lines <- strsplit(params$primer_sequences, "\n")[[1]]
    primer_lines <- trimws(primer_lines[nchar(trimws(primer_lines)) > 0])
    if (length(primer_lines) >= 1) primer_forward <- primer_lines[1]
    if (length(primer_lines) >= 2) primer_reverse <- primer_lines[2]
    cat("[WIRE] params.primers.forward:", primer_forward %||% "(none)", "\n")
    cat("[WIRE] params.primers.reverse:", primer_reverse %||% "(none)", "\n")
  } else {
    cat("[WIRE] params.primers: (omitted)\n")
  }

  # --- barcode sequences ---
  barcode_sequences <- NULL
  if (!is.null(params$barcode_sequences) && nchar(trimws(params$barcode_sequences)) > 0) {
    barcode_lines <- strsplit(params$barcode_sequences, "\n")[[1]]
    barcode_lines <- trimws(barcode_lines[nchar(trimws(barcode_lines)) > 0])
    if (length(barcode_lines) > 0) {
      barcode_sequences <- barcode_lines
      cat("[WIRE] input.barcodes.sequences:", length(barcode_lines), "entries\n")
    }
  }

  # --- barcoding_kit and ligation_kit ---
  barcoding_kit <- if (!is.null(params$barcoding_kit) && nchar(trimws(params$barcoding_kit)) > 0) trimws(params$barcoding_kit) else NULL
  ligation_kit  <- if (!is.null(params$ligation_kit)  && nchar(trimws(params$ligation_kit))  > 0) trimws(params$ligation_kit)  else NULL
  cat("[WIRE] barcoding_kit:", if (is.null(barcoding_kit)) "(omitted)" else barcoding_kit, "\n")
  cat("[WIRE] ligation_kit:",  if (is.null(ligation_kit))  "(omitted)" else ligation_kit,  "\n")

  # --- Kraken2 DB (required for lr_meta) ---
  # LR backend reads: tools.kraken2.db (NOT host.resources.kraken2_db.host_path)
  # Primary: params$kraken_db (direct path field)
  # Fallback: params$external_db_dir with database_type == "auto"|"kraken2"
  kraken_db <- if (!is.null(params$kraken_db) && nchar(trimws(params$kraken_db)) > 0) {
    trimws(params$kraken_db)
  } else if (!is.null(params$external_db_dir) && nchar(trimws(params$external_db_dir)) > 0) {
    db_type <- params$database_type %||% "auto"
    if (db_type %in% c("auto", "kraken2")) {
      cat("[WIRE] tools.kraken2.db: falling back to external_db_dir (type:", db_type, ")\n")
      trimws(params$external_db_dir)
    } else {
      ""
    }
  } else {
    ""
  }
  cat("[WIRE] tools.kraken2.db:", kraken_db, "\n")

  # --- human depletion ---
  # UI: checkboxInput("human_depletion") shown for lr_meta
  # Config: params.common.remove_host (integer: 1 or 0)
  remove_host <- if (!is.null(params$human_depletion) && isTRUE(params$human_depletion)) 1L else 0L
  cat("[WIRE] params.common.remove_host:", remove_host, "(from human_depletion =", isTRUE(params$human_depletion), ")\n")

  # --- output selected ---
  output_selected <- if (!is.null(params$output_selected) && length(params$output_selected) > 0) {
    as.character(params$output_selected)
  } else {
    c("all")
  }
  cat("[WIRE] output.selected:", paste(output_selected, collapse=", "), "\n")

  # --- postprocess enabled ---
  postprocess_enabled <- if (!is.null(params$enable_postprocess) && isTRUE(params$enable_postprocess)) 1L else 0L
  cat("[WIRE] postprocess.enabled:", postprocess_enabled, "\n")

  # --- VALENCIA auto-detect ---
  repo_root <- dirname(getwd())
  valencia_centroids_candidates <- c(
    file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv"),
    file.path(repo_root, "main", "tools", "VALENCIA", "CST_centroids_012920.csv")
  )
  valencia_centroids_path <- ""
  for (candidate in valencia_centroids_candidates) {
    if (file.exists(candidate)) {
      valencia_centroids_path <- candidate
      cat("[WIRE] valencia.centroids_csv: auto-detected at", valencia_centroids_path, "\n")
      break
    }
  }
  if (valencia_centroids_path == "") {
    valencia_centroids_path <- file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv")
    cat("[WIRE] valencia.centroids_csv: NOT FOUND - using default path\n")
  }

  # --- minimap2 human genome index auto-detection ---
  # Config: config$tools$minimap2$human_mmi + config$tools$minimap2$split_prefix
  # Pipeline reads: .tools.minimap2.human_mmi (lr_meta.sh, run_in_container.sh)
  # Matches WIZARD_REFERENCE_INDEXES naming (all 4 strategies, priority order).
  grch38_dir_lr <- file.path(repo_root, "main", "data", "reference", "human", "grch38")
  mmi_candidates_lr <- list(
    list(name = "GRCh38.primary_assembly.genome.mmi",         split = 0L),
    list(name = "GRCh38.primary_assembly.genome.lowmem.mmi",  split = 0L),
    list(name = "GRCh38.primary_assembly.genome.split2G.mmi", split = 1L),
    list(name = "GRCh38.primary_assembly.genome.split4G.mmi", split = 1L)
  )
  human_mmi_path_lr  <- ""
  minimap2_split_lr  <- 0L
  for (cand in mmi_candidates_lr) {
    p <- file.path(grch38_dir_lr, cand$name)
    if (file.exists(p)) {
      human_mmi_path_lr <- p
      minimap2_split_lr <- cand$split
      cat("[WIRE] tools.minimap2.human_mmi: auto-detected at", p, "\n")
      cat("[WIRE] tools.minimap2.split_prefix:", minimap2_split_lr, "\n")
      break
    }
  }
  if (human_mmi_path_lr == "") {
    cat("[WIRE] tools.minimap2.human_mmi: NOT FOUND - run Setup Wizard to build minimap2 index\n")
    if (remove_host == 1L) {
      cat("[WIRE] WARNING: remove_host=1 but no minimap2 index found - pipeline will fail\n")
    }
  }

  # --- build params.common ---
  params_common <- list(
    min_qscore  = quality_threshold,
    remove_host = remove_host,
    specimen    = specimen
  )
  if (!is.null(trim_adapter)) params_common$trim_adapter <- trim_adapter
  if (!is.null(demultiplex))  params_common$demultiplex  <- demultiplex

  # --- Kraken2 classification params ---
  # CLI reads: .tools.kraken2.vaginal.confidence, .tools.kraken2.vaginal.minimum_hit_groups
  #            .tools.kraken2.nonvaginal.confidence, .tools.kraken2.nonvaginal.minimum_hit_groups
  kraken_confidence     <- if (!is.null(params$kraken_confidence))     as.numeric(params$kraken_confidence)     else NULL
  kraken_min_hit_groups <- if (!is.null(params$kraken_min_hit_groups)) as.integer(params$kraken_min_hit_groups) else NULL
  cat("[WIRE] tools.kraken2.*.confidence:", if (is.null(kraken_confidence)) "(default)" else kraken_confidence, "\n")
  cat("[WIRE] tools.kraken2.*.minimum_hit_groups:", if (is.null(kraken_min_hit_groups)) "(default)" else kraken_min_hit_groups, "\n")

  # --- build tools block ---
  kraken2_obj <- list(db = kraken_db)
  if (!is.null(kraken_confidence) || !is.null(kraken_min_hit_groups)) {
    kp <- list()
    if (!is.null(kraken_confidence))     kp$confidence         <- kraken_confidence
    if (!is.null(kraken_min_hit_groups)) kp$minimum_hit_groups <- kraken_min_hit_groups
    kraken2_obj$vaginal    <- kp
    kraken2_obj$nonvaginal <- kp
  }
  tools_obj <- list(
    qfilter = list(enabled = 1L, min_q = quality_threshold),
    kraken2 = kraken2_obj
  )
  if (!is.null(min_read_length)) {
    tools_obj$qfilter$min_len <- min_read_length
  }

  # Bracken readlen: respect user wizard preference, auto-detect from DB, fallback to 1200.
  bracken_rl_pref <- params$bracken_readlen %||% "auto"
  bracken_readlen <- if (bracken_rl_pref == "auto") {
    db_path <- if (!is.null(params$kraken_db) && nchar(trimws(params$kraken_db)) > 0)
      trimws(params$kraken_db) else NULL
    available <- if (!is.null(db_path) && dir.exists(db_path)) {
      files <- list.files(db_path, pattern = "^database[0-9]+mers\\.kmer_distrib$")
      lens  <- suppressWarnings(
        as.integer(gsub("^database([0-9]+)mers\\.kmer_distrib$", "\\1", files)))
      lens[!is.na(lens)]
    } else integer(0)
    if (length(available) > 0) {
      chosen <- max(available)
      cat("[WIRE] bracken readlen: auto-detected", chosen, "mers from DB\n")
      chosen
    } else {
      cat("[WIRE] bracken readlen: auto fallback to 1200 (no DB path or no kmer_distrib)\n")
      1200L
    }
  } else {
    rl <- suppressWarnings(as.integer(bracken_rl_pref))
    cat("[WIRE] bracken readlen: user preference", rl, "mers\n")
    rl
  }
  tools_obj$bracken <- list(
    vaginal    = list(enabled = 1L, readlen = bracken_readlen),
    nonvaginal = list(enabled = 1L, readlen = bracken_readlen)
  )

  # minimap2 index: always output when found (pipeline ignores if remove_host=0)
  # Pipeline reads: .tools.minimap2.human_mmi + .tools.minimap2.split_prefix (lr_meta.sh)
  if (human_mmi_path_lr != "") {
    tools_obj$minimap2 <- list(
      human_mmi    = human_mmi_path_lr,
      split_prefix = minimap2_split_lr
    )
  }

  # Dorado settings (FAST5/POD5 only)
  if (input_format %in% c("fast5", "pod5")) {
    dorado_obj <- list()

    # Auto-detect Dorado binary for Docker (Linux version at tools/dorado/)
    # Wizard downloads Linux version to tools/dorado/ for use inside Docker container
    dorado_bin_host <- file.path(repo_root, "tools", "dorado", "bin", "dorado")

    if (!file.exists(dorado_bin_host)) {
      # Check for version-specific installations (e.g., dorado-0.9.6)
      tools_dir <- file.path(repo_root, "tools")
      dorado_dirs <- list.dirs(tools_dir, full.names = TRUE, recursive = FALSE)
      dorado_dirs <- dorado_dirs[grepl("^dorado-[0-9]", basename(dorado_dirs))]
      dorado_dirs <- dorado_dirs[!grepl("-host$", basename(dorado_dirs))]  # Skip macOS host binaries

      if (length(dorado_dirs) > 0) {
        # Use the first (or newest) version found
        dorado_dirs <- sort(dorado_dirs, decreasing = TRUE)
        dorado_bin_host <- file.path(dorado_dirs[1], "bin", "dorado")
      }
    }

    # Binary path — tools/ is at the repo root, which is OUTSIDE main/.
    # Docker mounts main/ at /work, so /work/tools/ does NOT exist.
    # run_in_container.sh also mounts /Users:/Users (macOS) and REPO_ROOT:REPO_ROOT,
    # so the host absolute path of the binary is directly accessible inside the container.
    if (file.exists(dorado_bin_host)) {
      dorado_obj$bin       <- dorado_bin_host   # tools.dorado.bin  (nested, legacy)
      tools_obj$dorado_bin <- dorado_bin_host   # tools.dorado_bin  (flat — what lr_meta.sh reads)
      cat("[WIRE] tools.dorado_bin:", dorado_bin_host, "\n")
    } else {
      cat("[WIRE] WARNING: Dorado Linux binary not found under tools/\n")
      cat("[WIRE] Run Setup Wizard to download Dorado for Docker\n")
    }

    # Model: Use NAME ONLY like CLI does - script will combine with models directory
    dorado_model <- if (!is.null(params$dorado_model) && nchar(trimws(params$dorado_model)) > 0) {
      trimws(params$dorado_model)
    } else {
      # Auto-detect: prefer v3.5.2 if installed (for 4kHz data), else v5.2.0
      models_dir_host <- file.path(repo_root, "tools", "models", "dorado")
      v352_name <- "dna_r10.4.1_e8.2_400bps_hac@v3.5.2"
      v420_name <- "dna_r10.4.1_e8.2_400bps_hac@v4.2.0"
      v520_name <- "dna_r10.4.1_e8.2_400bps_hac@v5.2.0"

      v352_path <- file.path(models_dir_host, v352_name)
      v420_path <- file.path(models_dir_host, v420_name)
      v520_path <- file.path(models_dir_host, v520_name)

      if (dir.exists(v352_path)) {
        cat("[WIRE] Auto-detected v3.5.2 model for 4kHz data\n")
        v352_name
      } else if (dir.exists(v420_path)) {
        cat("[WIRE] Auto-detected v4.2.0 model\n")
        v420_name
      } else if (dir.exists(v520_path)) {
        cat("[WIRE] Auto-detected v5.2.0 model\n")
        v520_name
      } else {
        cat("[WIRE] No models found, defaulting to v5.2.0 (will download on demand)\n")
        v520_name
      }
    }
    dorado_obj$model <- dorado_model
    cat("[WIRE] tools.dorado.model:", dorado_model, "\n")

    # Barcoding/ligation kit inside dorado block for FAST5/POD5
    if (!is.null(barcoding_kit)) dorado_obj$barcode_kit   <- barcoding_kit
    if (!is.null(ligation_kit)) {
      dorado_obj$ligation_kit   <- ligation_kit
      dorado_obj$sequencing_kit <- ligation_kit  # Dorado 0.9.6 requires --sequencing-kit for trim
      cat("[WIRE] tools.dorado.sequencing_kit:", ligation_kit, "(copied from ligation_kit)\n")
    }
    if (length(dorado_obj) > 0) tools_obj$dorado <- dorado_obj
  } else {
    # FASTQ: kit values go in top-level tools block
    if (!is.null(barcoding_kit)) tools_obj$barcoding_kit <- barcoding_kit
    if (!is.null(ligation_kit))  tools_obj$ligation_kit  <- ligation_kit
  }

  # --- assemble config ---
  config <- list(
    pipeline_id = "lr_meta",

    run = list(
      work_dir        = params$output_dir,
      run_id          = params$run_id,
      force_overwrite = 1L
    ),

    technology = unname(technology),
    specimen   = specimen,

    input = input_obj,

    resources = list(threads = threads),

    params = list(
      common   = params_common,
      seq_type = if (technology == "ONT") "map-ont" else "map-pb"
    ),

    tools = tools_obj,

    output = list(selected = output_selected),

    postprocess = list(
      enabled = postprocess_enabled,
      steps = list(
        heatmap            = pp_step("heatmap",     output_selected, postprocess_enabled),
        piechart           = pp_step("pie_chart",   output_selected, postprocess_enabled),
        stacked_bar        = pp_step("stacked_bar", output_selected, postprocess_enabled),
        results_csv        = postprocess_enabled,  # always on — tables always generated
        relative_abundance = 0L,
        valencia           = 0L  # updated below for vaginal
      )
    )
  )

  # --- run scope (conditional) ---
  if (!is.null(run_scope)) config$run$scope <- run_scope

  # --- primer sequences (conditional) ---
  if (!is.null(primer_forward) || !is.null(primer_reverse)) {
    primers_obj <- list()
    if (!is.null(primer_forward)) primers_obj$forward <- primer_forward
    if (!is.null(primer_reverse)) primers_obj$reverse <- primer_reverse
    config$params$primers <- primers_obj
  }

  # --- barcode sequences (conditional) ---
  if (!is.null(barcode_sequences)) {
    config$input$barcodes <- list(sequences = barcode_sequences)
  }

  # --- VALENCIA (conditional: vaginal only) ---
  if (specimen == "vaginal") {
    valencia_enabled <- if (!is.null(params$valencia) && params$valencia == "yes") 1L else 0L
    config$valencia <- list(
      enabled       = valencia_enabled,
      mode          = "auto",
      centroids_csv = valencia_centroids_path
    )
    cat("[WIRE] valencia.enabled:", valencia_enabled, "| centroids_csv:", valencia_centroids_path, "\n")
    config$postprocess$steps$valencia <- if (postprocess_enabled == 1L && valencia_enabled == 1L) 1L else 0L
    cat("[WIRE] postprocess.steps.valencia:", config$postprocess$steps$valencia, "\n")
  } else {
    cat("[WIRE] valencia: omitted (specimen is", specimen, "not vaginal)\n")
    config$postprocess$steps$valencia <- 0L
  }

  # --- sample_map (barcode → sample name) ---
  sample_map <- if (!is.null(params$sample_map) && length(params$sample_map) > 0) {
    params$sample_map
  } else NULL

  if (!is.null(sample_map)) {
    config$sample_map   <- sample_map
    sample_sheet_path   <- file.path(params$output_dir, params$run_id, "sample_sheet.tsv")
    config$sample_sheet <- sample_sheet_path

    # Embed sample_sheet path in each enabled postprocess step so R scripts receive it
    for (sn in c("heatmap", "piechart", "stacked_bar", "results_csv")) {
      current_val <- config$postprocess$steps[[sn]]
      if (!is.null(current_val) && identical(current_val, 1L)) {
        config$postprocess$steps[[sn]] <- list(
          enabled = 1L,
          params  = list(sample_sheet = sample_sheet_path)
        )
      }
    }
    cat("[WIRE] sample_map:", length(sample_map), "entries\n")
    cat("[WIRE] sample_sheet:", sample_sheet_path, "\n")
  }

  # --- pre-return audit ---
  cat("\n[AUDIT] lr_meta config field check:\n")
  cat("  pipeline_id:                   ", config$pipeline_id, "\n")
  cat("  run.work_dir:                  ", config$run$work_dir, "\n")
  cat("  run.run_id:                    ", config$run$run_id, "\n")
  cat("  run.scope:                     ", if (!is.null(config$run$scope)) config$run$scope else "(none)", "\n")
  cat("  technology:                    ", config$technology, "\n")
  cat("  specimen:                      ", config$specimen, "\n")
  cat("  input.style:                   ", config$input$style, "\n")
  cat("  resources.threads:             ", config$resources$threads, "\n")
  cat("  params.common.remove_host:     ", config$params$common$remove_host, "\n")
  cat("  params.common.trim_adapter:    ", if (!is.null(config$params$common$trim_adapter)) config$params$common$trim_adapter else "(omitted)", "\n")
  cat("  params.common.demultiplex:     ", if (!is.null(config$params$common$demultiplex)) config$params$common$demultiplex else "(omitted)", "\n")
  cat("  tools.qfilter.min_q:           ", config$tools$qfilter$min_q, "\n")
  cat("  tools.kraken2.db:              ", config$tools$kraken2$db, "\n")
  cat("  tools.kraken2.*.confidence:    ", if (!is.null(config$tools$kraken2$vaginal$confidence)) config$tools$kraken2$vaginal$confidence else "(default)", "\n")
  cat("  tools.kraken2.*.min_hit_groups:", if (!is.null(config$tools$kraken2$vaginal$minimum_hit_groups)) config$tools$kraken2$vaginal$minimum_hit_groups else "(default)", "\n")
  cat("  tools.minimap2.human_mmi:      ", if (!is.null(config$tools$minimap2$human_mmi)) config$tools$minimap2$human_mmi else "(not set)", "\n")
  cat("  output.selected:               ", paste(config$output$selected, collapse=", "), "\n")
  cat("  postprocess.enabled:           ", config$postprocess$enabled, "\n")
  cat("  postprocess.steps.heatmap:     ", .fmt_step(config$postprocess$steps$heatmap), "\n")
  cat("  postprocess.steps.piechart:    ", .fmt_step(config$postprocess$steps$piechart), "\n")
  cat("  postprocess.steps.stacked_bar: ", .fmt_step(config$postprocess$steps$stacked_bar), "\n")
  cat("  postprocess.steps.results_csv: ", .fmt_step(config$postprocess$steps$results_csv), "(always on)\n")
  cat("  postprocess.steps.valencia:    ", config$postprocess$steps$valencia, "\n")
  if (!is.null(config$valencia)) cat("  valencia.enabled:              ", config$valencia$enabled, "\n")
  if (!is.null(config$tools$dorado)) {
    cat("  tools.dorado.barcode_kit:      ", config$tools$dorado$barcode_kit %||% "(none)", "\n")
    cat("  tools.dorado.ligation_kit:     ", config$tools$dorado$ligation_kit %||% "(none)", "\n")
    cat("  tools.dorado.sequencing_kit:   ", config$tools$dorado$sequencing_kit %||% "(none)", "\n")
  }
  cat("========== LR_META CONFIG COMPLETE ==========\n\n")

  config
}

save_config <- function(config, run_id) {
  outputs_dir <- get_outputs_directory()

  dir.create(outputs_dir, recursive = TRUE, showWarnings = FALSE)

  # Defensive check: ensure postprocess block is always present and complete
  if (is.null(config$postprocess)) {
    cat("[WARNING] postprocess block was missing from config - defaulting to disabled\n")
    config$postprocess <- list(
      enabled = 0L,
      steps = list(
        heatmap = 0L, piechart = 0L, stacked_bar = 0L,
        results_csv = 0L, relative_abundance = 0L, valencia = 0L
      )
    )
  }

  cat("\n========== FINAL CONFIG OBJECT ==========\n")
  cat("Structure:\n")
  print(str(config))
  cat("\nJSON representation:\n")
  cat(jsonlite::toJSON(config, auto_unbox = TRUE, pretty = TRUE))
  cat("\n=========================================\n\n")

  config_file <- file.path(outputs_dir, paste0("config_", run_id, ".json"))
  jsonlite::write_json(config, config_file, pretty = TRUE, auto_unbox = TRUE)

  cat("Config written to:", config_file, "\n")

  # Write sample sheet TSV if sample_map is present
  if (!is.null(config$sample_map) && length(config$sample_map) > 0 && !is.null(config$sample_sheet)) {
    tsv_path <- config$sample_sheet
    dir.create(dirname(tsv_path), recursive = TRUE, showWarnings = FALSE)
    tsv_df <- data.frame(
      barcode     = names(config$sample_map),
      sample_name = unlist(config$sample_map),
      stringsAsFactors = FALSE
    )
    write.table(tsv_df, tsv_path, sep = "\t", row.names = FALSE, quote = FALSE)
    cat("Sample sheet written to:", tsv_path, "\n")
  }

  # Verify the written file contains postprocess steps
  written <- jsonlite::fromJSON(config_file)
  cat("[VERIFY] postprocess.enabled =", written$postprocess$enabled, "\n")
  cat("[VERIFY] postprocess.steps.piechart =", .fmt_step(written$postprocess$steps$piechart), "\n")
  cat("[VERIFY] postprocess.steps.heatmap =", .fmt_step(written$postprocess$steps$heatmap), "\n")
  cat("[VERIFY] postprocess.steps.results_csv =", .fmt_step(written$postprocess$steps$results_csv), "\n")

  config_file
}

load_config <- function(run_id) {
  outputs_dir <- get_outputs_directory()
  config_file <- file.path(outputs_dir, run_id, "config.json")

  if (!file.exists(config_file)) {
    return(NULL)
  }

  jsonlite::fromJSON(config_file)
}

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || is.na(x)) y else x
}

validate_dependencies <- function(config) {
  errors   <- character(0)
  warnings <- character(0)

  if (config$pipeline_id == "sr_amp") {
    # QIIME2 SILVA classifier (warning if missing - pipeline degrades gracefully)
    classifier_path <- config$qiime2$classifier$qza
    if (is.null(classifier_path) || classifier_path == "" || !file.exists(classifier_path)) {
      warnings <- c(warnings, "QIIME2 SILVA classifier not found. Taxonomy classification will be skipped.")
      warnings <- c(warnings, "Run Setup Wizard to download SILVA classifier.")
    }

    # VALENCIA centroids (error if enabled and missing - hard failure)
    if (!is.null(config$valencia) && config$valencia$enabled == 1) {
      centroids_path <- config$valencia$centroids_csv
      if (is.null(centroids_path) || centroids_path == "" || !file.exists(centroids_path)) {
        errors <- c(errors, "VALENCIA is enabled but CST_centroids_012920.csv not found.")
        errors <- c(errors, sprintf("Expected at: %s", centroids_path))
        errors <- c(errors, "Run Setup Wizard to download VALENCIA or disable VALENCIA.")
      }
    }
  }

  list(errors = errors, warnings = warnings, valid = length(errors) == 0)
}
