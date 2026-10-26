#!/usr/bin/env Rscript
library(shiny)
library(shinyjs)

get_repo_root <- function() { normalizePath(file.path(getwd(), "..")) }
setup_marker_file <- file.path(get_repo_root(), ".setup_complete")

# Detect what's already installed
detect_installed <- function() {
  repo_root <- get_repo_root()

  installed <- list(
    databases = c(),
    tools = c(),
    models = c()
  )

  # Check databases
  for (i in seq_along(DATABASES)) {
    db <- DATABASES[[i]]
    db_path <- NULL

    if (!is.null(db$is_single_file) && db$is_single_file) {
      # Single file database
      db_path <- file.path(repo_root, "main", "data", db$dest_subdir, db$dest_filename)
      if (file.exists(db_path)) {
        installed$databases <- c(installed$databases, db$id)
      }
    } else {
      # Directory-based database
      db_path <- file.path(repo_root, "main", "data", "databases", db$id)
      if (dir.exists(db_path)) {
        installed$databases <- c(installed$databases, db$id)
      }
    }
  }

  # Check tools (VALENCIA)
  valencia_dir <- file.path(repo_root, "tools", "VALENCIA")
  if (dir.exists(valencia_dir)) {
    centroids <- file.path(valencia_dir, "CST_centroids_012920.csv")
    if (file.exists(centroids)) {
      installed$tools <- c(installed$tools, "valencia")
    }
  }

  # Check Dorado models
  models_dir <- file.path(repo_root, "tools", "models")
  if (dir.exists(models_dir)) {
    for (i in seq_along(DORADO_MODELS)) {
      model <- DORADO_MODELS[[i]]
      model_dir <- file.path(models_dir, model$id)
      if (dir.exists(model_dir)) {
        installed$models <- c(installed$models, model$id)
      }
    }
  }

  return(installed)
}

DATABASES <- list(
  list(id = "kraken2-standard-8", name = "Kraken2 Standard-8", desc = "8GB Bacteria/Archaea/Viral/Human", size = "8", pipelines = "sr_meta, lr_meta",
       url = "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240605.tar.gz", is_tarball = TRUE),
  list(id = "kraken2-standard-16", name = "Kraken2 Standard-16", desc = "16GB Bacteria/Archaea/Viral/Human", size = "16", pipelines = "sr_meta, lr_meta",
       url = "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_16gb_20240605.tar.gz", is_tarball = TRUE),
  list(id = "emu-default", name = "Emu Default", desc = "17K species for lr_amp", size = "0.1", pipelines = "lr_amp",
       url = "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da8a656946a0023a7a54ef", is_tarball = TRUE),
  list(id = "emu-silva", name = "Emu SILVA", desc = "100K+ species for lr_amp", size = "0.6", pipelines = "lr_amp",
       url = "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da837c7d0187023fbc4993", is_tarball = TRUE),
  list(id = "emu-rdp", name = "Emu RDP (RECOMMENDED)", desc = "280K+ species for lr_amp", size = "1.3", pipelines = "lr_amp",
       url = "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da84611e96860221b25460", is_tarball = TRUE),
  list(id = "qiime2-silva-138", name = "QIIME2 SILVA 138", desc = "REQUIRED for sr_amp", size = "0.21", pipelines = "sr_amp",
       url = "https://data.qiime2.org/classifiers/sklearn-1.4.2/silva/silva-138-99-nb-classifier.qza",
       is_single_file = TRUE, dest_subdir = "reference/qiime2", dest_filename = "silva-138-99-nb-classifier.qza"),
  list(id = "human-grch38", name = "Human GRCh38", desc = "For host depletion", size = "0.9", pipelines = "sr_meta, lr_meta",
       url = "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz",
       is_single_file = TRUE, dest_subdir = "reference/human/grch38", dest_filename = "GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz")
)

TOOLS <- list(
  list(id = "valencia",
       name = "VALENCIA",
       desc = "Vaginal CST classification",
       size = "2 MB",
       samples = "vaginal",
       url = "https://github.com/ravel-lab/VALENCIA/archive/refs/heads/master.zip")
)

DORADO_MODELS <- list(
  list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.2.0", name = "Dorado HAC v5.2.0 (RECOMMENDED)", desc = "High accuracy for modern 5kHz data", size = "400 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_sup@v5.2.0", name = "Dorado SUP v5.2.0", desc = "Super accuracy for 5kHz data", size = "400 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.0.0", name = "Dorado HAC v5.0.0", desc = "High accuracy stable release", size = "400 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_hac@v4.3.0", name = "Dorado HAC v4.3.0", desc = "Legacy high accuracy", size = "400 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_hac@v4.2.0", name = "Dorado HAC v4.2.0", desc = "Legacy baseline", size = "400 MB")
)

css <- "
body { font-family: -apple-system, system-ui, sans-serif; margin: 0; background: #f9fafb; }
.wizard-container { min-height: 100vh; padding: 40px 24px; }
.wizard-header { text-align: center; margin-bottom: 48px; }
.wizard-header h1 { font-size: 32px; font-weight: 600; color: #111827; margin-bottom: 12px; }
.wizard-header .subtitle { color: #6b7280; font-size: 16px; }
.wizard-content { max-width: 800px; margin: 0 auto; }
.wizard-card { background: white; border: 1px solid #e5e7eb; border-radius: 12px; padding: 32px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); margin-bottom: 24px; }
.step-header { display: flex; align-items: center; gap: 16px; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 2px solid #e5e7eb; }
.step-number { background: #2563eb; color: white; width: 40px; height: 40px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 18px; font-weight: 600; }
.step-title { font-size: 22px; font-weight: 600; color: #111827; }
.step-desc { color: #6b7280; font-size: 14px; margin-bottom: 20px; line-height: 1.5; }
.option-list { display: flex; flex-direction: column; gap: 12px; }
.option { display: flex; align-items: flex-start; gap: 12px; padding: 16px; border: 2px solid #e5e7eb; border-radius: 8px; transition: all 0.2s; cursor: pointer; position: relative; }
.option:hover { border-color: #2563eb; background: #f9fafb; }
.option.installed { border-color: #10b981; background: #ecfdf5; }
.option.installed:hover { border-color: #059669; background: #d1fae5; }
.installed-badge { position: absolute; top: 12px; right: 12px; background: #10b981; color: white; padding: 4px 12px; border-radius: 12px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
.option input[type='checkbox'] { margin-top: 2px; width: 18px; height: 18px; pointer-events: none; }
.option-content { flex: 1; }
.option-name { font-weight: 600; color: #111827; font-size: 15px; margin-bottom: 4px; }
.option-desc { color: #6b7280; font-size: 13px; margin-bottom: 4px; }
.option-meta { color: #9ca3af; font-size: 12px; }
.docker-status { display: flex; align-items: center; gap: 12px; padding: 16px; background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; margin-top: 12px; }
.status-icon { width: 28px; height: 28px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 16px; }
.status-ok { background: #dcfce7; color: #059669; }
.status-error { background: #fee2e2; color: #dc2626; }
.status-text { flex: 1; color: #374151; font-size: 14px; font-weight: 500; }
.progress-section { margin-top: 32px; padding-top: 32px; border-top: 2px solid #e5e7eb; }
.progress-bar-bg { background: #e5e7eb; height: 12px; border-radius: 6px; overflow: hidden; margin: 16px 0; }
.progress-bar { background: linear-gradient(90deg, #2563eb 0%, #3b82f6 100%); height: 100%; transition: width 0.3s; }
.progress-text { color: #6b7280; font-size: 14px; margin-bottom: 8px; }
.log-output { background: #111827; border-radius: 8px; padding: 16px; font-family: 'SF Mono', 'Courier New', monospace; font-size: 13px; color: #d1d5db; max-height: 400px; overflow-y: auto; margin-top: 16px; line-height: 1.5; }
.log-line { margin-bottom: 2px; white-space: pre-wrap; word-break: break-word; }
.log-error { color: #f87171; }
.log-success { color: #34d399; }
.wizard-footer { display: flex; justify-content: space-between; align-items: center; margin-top: 32px; }
.btn { padding: 12px 24px; border-radius: 8px; font-weight: 500; font-size: 14px; border: none; cursor: pointer; transition: all 0.2s; }
.btn-primary { background: #2563eb; color: white; }
.btn-primary:hover:not(:disabled) { background: #1d4ed8; }
.btn-primary:disabled { background: #9ca3af; cursor: not-allowed; opacity: 0.6; }
.btn-secondary { background: #f3f4f6; color: #374151; }
.btn-secondary:hover { background: #e5e7eb; }
.dna-icon { font-size: 48px; margin-bottom: 16px; }
"

js_code <- '
$(document).on("click", ".option", function(e) {
  if ($(e.target).is("input[type=checkbox]")) return;
  var checkbox = $(this).find("input[type=checkbox]");
  checkbox.prop("checked", !checkbox.prop("checked")).trigger("change");
});
'

ui <- fluidPage(
  useShinyjs(),
  tags$head(tags$style(HTML(css)), tags$script(HTML(js_code))),

  div(class = "wizard-container",
      div(class = "wizard-header",
          div(class = "dna-icon", "🧬"),
          h1("STAMINA-BIOME Setup Wizard"),
          p(class = "subtitle", "Configure databases, tools, and models for bioinformatics analysis")),

      div(class = "wizard-content",
          div(class = "wizard-card",
              div(class = "step-header", span(class = "step-number", "1"), span(class = "step-title", "Docker Check")),
              div(class = "step-desc", "STAMINA-BIOME requires Docker to run bioinformatics pipelines in isolated containers."),
              actionButton("check_docker", "Check Docker Status", class = "btn btn-secondary"),
              div(id = "docker-status-container", class = "docker-status", style = "display: none;",
                  div(id = "docker-icon", class = "status-icon"),
                  div(id = "docker-text", class = "status-text"))),

          div(class = "wizard-card",
              div(class = "step-header", span(class = "step-number", "2"), span(class = "step-title", "Reference Databases")),
              div(class = "step-desc", "Select databases for taxonomic classification. Downloads may take several minutes."),
              uiOutput("databases_ui")),

          div(class = "wizard-card",
              div(class = "step-header", span(class = "step-number", "3"), span(class = "step-title", "Analysis Tools")),
              div(class = "step-desc", "Optional specialized tools for specific sample types."),
              uiOutput("tools_ui")),

          div(class = "wizard-card",
              div(class = "step-header", span(class = "step-number", "4"), span(class = "step-title", "Dorado Basecalling Models")),
              div(class = "step-desc", "Required for FAST5/POD5 basecalling in long-read pipelines."),
              uiOutput("models_ui")),

          div(id = "progress-section", class = "wizard-card progress-section", style = "display: none;",
              h3(style = "margin-bottom: 16px; font-size: 18px; color: #111827;", "Installation Progress"),
              div(id = "progress-text", class = "progress-text", "Initializing..."),
              div(class = "progress-bar-bg", div(id = "progress-bar", class = "progress-bar", style = "width: 0%;")),
              div(id = "install-log", class = "log-output")),

          div(class = "wizard-footer",
              actionButton("skip_setup", "Skip Setup", class = "btn btn-secondary"),
              actionButton("start_install", "Download & Install", class = "btn btn-primary"))))
)

server <- function(input, output, session) {

  # Detect what's already installed
  installed <- detect_installed()

  # Render databases with installed indicators
  output$databases_ui <- renderUI({
    div(class = "option-list",
        lapply(seq_along(DATABASES), function(i) {
          db <- DATABASES[[i]]
          is_installed <- db$id %in% installed$databases

          option_class <- if (is_installed) "option installed" else "option"

          div(class = option_class,
              checkboxInput(paste0("db_", i), "", width = "20px"),
              div(class = "option-content",
                  div(class = "option-name", db$name),
                  div(class = "option-desc", db$desc),
                  div(class = "option-meta", sprintf("Size: ~%s GB | Used by: %s", db$size, db$pipelines))),
              if (is_installed) div(class = "installed-badge", "✓ Installed") else NULL)
        }))
  })

  # Render tools with installed indicators
  output$tools_ui <- renderUI({
    div(class = "option-list",
        lapply(seq_along(TOOLS), function(i) {
          tool <- TOOLS[[i]]
          is_installed <- tool$id %in% installed$tools

          option_class <- if (is_installed) "option installed" else "option"

          div(class = option_class,
              checkboxInput(paste0("tool_", i), "", value = TRUE, width = "20px"),
              div(class = "option-content",
                  div(class = "option-name", tool$name),
                  div(class = "option-desc", tool$desc),
                  div(class = "option-meta", sprintf("Size: %s | For: %s samples", tool$size, tool$samples))),
              if (is_installed) div(class = "installed-badge", "✓ Installed") else NULL)
        }))
  })

  # Render Dorado models with installed indicators
  output$models_ui <- renderUI({
    div(class = "option-list",
        lapply(seq_along(DORADO_MODELS), function(i) {
          model <- DORADO_MODELS[[i]]
          is_installed <- model$id %in% installed$models

          option_class <- if (is_installed) "option installed" else "option"

          div(class = option_class,
              checkboxInput(paste0("model_", i), "", value = (i == 1), width = "20px"),
              div(class = "option-content",
                  div(class = "option-name", model$name),
                  div(class = "option-desc", model$desc),
                  div(class = "option-meta", sprintf("Size: ~%s", model$size))),
              if (is_installed) div(class = "installed-badge", "✓ Installed") else NULL)
        }))
  })

  observeEvent(input$check_docker, {
    show("docker-status-container")
    result <- tryCatch({
      system2("docker", args = c("info"), stdout = TRUE, stderr = TRUE, timeout = 5)
    }, error = function(e) NULL)
    if (!is.null(result) && (is.null(attr(result, "status")) || attr(result, "status") == 0)) {
      runjs("$('#docker-icon').removeClass().addClass('status-icon status-ok').html('✓');")
      runjs("$('#docker-text').text('Docker is installed and running');")
    } else {
      runjs("$('#docker-icon').removeClass().addClass('status-icon status-error').html('✗');")
      runjs("$('#docker-text').text('Docker is not running or not installed');")
    }
  })

  observe({ shinyjs::delay(500, click("check_docker")) })

  observeEvent(input$skip_setup, {
    writeLines(format(Sys.time()), setup_marker_file)
    showNotification("Setup skipped. Run 'python3 -m cli setup' from CLI to configure later.", type = "warning", duration = 10)
    Sys.sleep(1)
    stopApp(returnValue = "skipped")
  })

  observeEvent(input$start_install, {
    selected_dbs <- c(); selected_tools <- c(); selected_models <- c()
    for (i in seq_along(DATABASES)) if (isTRUE(input[[paste0("db_", i)]])) selected_dbs <- c(selected_dbs, i)
    for (i in seq_along(TOOLS)) if (isTRUE(input[[paste0("tool_", i)]])) selected_tools <- c(selected_tools, i)
    for (i in seq_along(DORADO_MODELS)) if (isTRUE(input[[paste0("model_", i)]])) selected_models <- c(selected_models, i)

    total_items <- length(selected_dbs) + length(selected_tools) + length(selected_models)
    if (total_items == 0) {
      showNotification("No items selected. Please select at least one item to install.", type = "warning")
      return()
    }

    show("progress-section")
    disable("start_install")
    disable("skip_setup")

    add_log <- function(msg, type = "info") {
      safe_msg <- gsub("'", "\\\\'", gsub("\n", " ", msg))
      safe_msg <- gsub("\"", "&quot;", safe_msg)
      log_class <- if(type == "error") "log-error" else if(type == "success") "log-success" else ""
      runjs(sprintf("$('#install-log').append($('<div>').addClass('log-line %s').text('%s')).scrollTop($('#install-log')[0].scrollHeight);", log_class, safe_msg))
    }

    update_progress <- function(pct, text) {
      runjs(sprintf("$('#progress-bar').css('width', '%d%%');", pct))
      runjs(sprintf("$('#progress-text').text('%s');", gsub("'", "\\\\'", text)))
    }

    repo_root <- get_repo_root()
    data_dir <- file.path(repo_root, "main", "data", "databases")
    tools_dir <- file.path(repo_root, "tools")
    models_dir <- file.path(tools_dir, "models", "dorado")
    dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
    dir.create(models_dir, recursive = TRUE, showWarnings = FALSE)

    current <- 0
    failed_items <- c()
    success_count <- 0

    add_log("=== STAMINA-BIOME Setup Wizard ===")
    add_log(sprintf("Repository: %s", repo_root))
    add_log(sprintf("Total items: %d", total_items))
    add_log("")

    # Databases
    if (length(selected_dbs) > 0) {
      add_log(">>> Installing Databases")
      add_log("")
      for (idx in selected_dbs) {
        current <- current + 1
        db <- DATABASES[[idx]]
        update_progress(round((current / total_items) * 100), sprintf("Installing %s (%d/%d)", db$name, current, total_items))
        add_log(sprintf("Installing: %s (~%s GB)", db$name, db$size))

        # Check if already exists
        if (isTRUE(db$is_single_file)) {
          dest_dir <- file.path(repo_root, "main", "data", db$dest_subdir)
          dest_file <- file.path(dest_dir, db$dest_filename)
          if (file.exists(dest_file) && file.size(dest_file) > 1000000) {
            add_log(sprintf("%s already installed (%.1f MB)", db$name, file.size(dest_file) / 1024 / 1024), "success")
            success_count <- success_count + 1
            add_log("")
            next
          }
        } else {
          db_path <- file.path(data_dir, db$id)
          if (dir.exists(db_path) && length(list.files(db_path)) > 0) {
            add_log(sprintf("%s already installed", db$name), "success")
            success_count <- success_count + 1
            add_log("")
            next
          }
        }

        start_time <- Sys.time()

        tryCatch({
          if (isTRUE(db$is_single_file)) {
            # Single file download
            dest_dir <- file.path(repo_root, "main", "data", db$dest_subdir)
            dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
            dest_file <- file.path(dest_dir, db$dest_filename)

            add_log(sprintf("Downloading from: %s", db$url))
            download.file(db$url, dest_file, mode = "wb", quiet = FALSE, method = "auto")

            elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

            if (file.exists(dest_file) && file.size(dest_file) > 1000000) {
              size_mb <- file.size(dest_file) / 1024 / 1024
              add_log(sprintf("Downloaded: %.1f MB", size_mb))
              add_log(sprintf("✓ %s completed (%.1fs)", db$name, elapsed), "success")
              success_count <- success_count + 1
            } else {
              add_log(sprintf("✗ %s failed: file too small or missing", db$name), "error")
              failed_items <- c(failed_items, db$name)
              if (file.exists(dest_file)) unlink(dest_file)
            }
          } else {
            # Tarball download
            archive_path <- file.path(data_dir, sprintf("%s.tar.gz", db$id))
            dest_path <- file.path(data_dir, db$id)

            add_log(sprintf("Downloading from: %s", db$url))
            download.file(db$url, archive_path, mode = "wb", quiet = FALSE, method = "auto")

            if (!file.exists(archive_path) || file.size(archive_path) < 1000000) {
              add_log(sprintf("✗ %s failed: download failed or file too small", db$name), "error")
              failed_items <- c(failed_items, db$name)
              if (file.exists(archive_path)) unlink(archive_path)
              add_log("")
              next
            }

            archive_mb <- file.size(archive_path) / 1024 / 1024
            add_log(sprintf("Downloaded: %.1f MB", archive_mb))
            add_log("Extracting tarball...")

            dir.create(dest_path, recursive = TRUE, showWarnings = FALSE)
            untar_result <- untar(archive_path, exdir = dest_path, tar = "internal")

            elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

            if (untar_result == 0 && dir.exists(dest_path) && length(list.files(dest_path)) > 0) {
              unlink(archive_path)
              add_log(sprintf("✓ %s completed (%.1fs)", db$name, elapsed), "success")
              success_count <- success_count + 1
            } else {
              add_log(sprintf("✗ %s failed: extraction failed", db$name), "error")
              failed_items <- c(failed_items, db$name)
              unlink(archive_path, force = TRUE)
              unlink(dest_path, recursive = TRUE, force = TRUE)
            }
          }
        }, error = function(e) {
          elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
          add_log(sprintf("✗ %s failed: %s (%.1fs)", db$name, e$message, elapsed), "error")
          failed_items <- c(failed_items, db$name)
        })
        add_log("")
      }
    }

    # Tools
    if (length(selected_tools) > 0) {
      add_log(">>> Installing Tools")
      add_log("")
      for (idx in selected_tools) {
        current <- current + 1
        tool <- TOOLS[[idx]]
        update_progress(round((current / total_items) * 100), sprintf("Installing %s (%d/%d)", tool$name, current, total_items))
        add_log(sprintf("Installing: %s", tool$name))

        tool_dest <- file.path(tools_dir, toupper(tool$id))
        if (dir.exists(tool_dest) && length(list.files(tool_dest)) > 0) {
          add_log(sprintf("%s already installed", tool$name), "success")
          success_count <- success_count + 1
          add_log("")
          next
        }

        archive_path <- file.path(tools_dir, paste0(tool$id, ".zip"))
        dir.create(tools_dir, recursive = TRUE, showWarnings = FALSE)

        start_time <- Sys.time()

        tryCatch({
          add_log(sprintf("Downloading from: %s", tool$url))
          download.file(tool$url, archive_path, mode = "wb", quiet = FALSE, method = "auto")

          if (!file.exists(archive_path) || file.size(archive_path) < 100000) {
            add_log(sprintf("✗ %s failed: download failed", tool$name), "error")
            failed_items <- c(failed_items, tool$name)
            if (file.exists(archive_path)) unlink(archive_path)
            add_log("")
            next
          }

          elapsed1 <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
          add_log(sprintf("Downloaded (%.1fs)", elapsed1))
          add_log("Extracting archive...")

          temp_extract <- file.path(tools_dir, paste0(tool$id, "_temp"))
          unzip(archive_path, exdir = temp_extract)

          top_dirs <- list.dirs(temp_extract, full.names = TRUE, recursive = FALSE)
          if (length(top_dirs) == 1) {
            file.rename(top_dirs[1], tool_dest)
            unlink(temp_extract, recursive = TRUE)
          } else {
            file.rename(temp_extract, tool_dest)
          }

          unlink(archive_path)

          if (tool$id == "valencia") {
            centroids <- file.path(tool_dest, "CST_centroids_012920.csv")
            if (file.exists(centroids)) {
              add_log(sprintf("VALENCIA centroids: %s", basename(centroids)))
            }
          }

          elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
          add_log(sprintf("✓ %s installed (%.1fs)", tool$name, elapsed), "success")
          success_count <- success_count + 1
        }, error = function(e) {
          elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
          add_log(sprintf("✗ %s failed: %s (%.1fs)", tool$name, e$message, elapsed), "error")
          failed_items <- c(failed_items, tool$name)
          if (file.exists(archive_path)) unlink(archive_path)
        })
        add_log("")
      }
    }

    # Models
    if (length(selected_models) > 0) {
      add_log(">>> Installing Dorado Models")
      add_log("")

      dorado_bin <- NULL
      machine <- Sys.info()["machine"]
      sysname <- Sys.info()["sysname"]

      if (sysname == "Darwin") {
        host_platform <- ifelse(machine == "arm64", "osx-arm64", "osx-x64")
        dorado_host_dir <- file.path(tools_dir, "dorado-host")
        dorado_bin <- file.path(dorado_host_dir, "bin", "dorado")

        if (!file.exists(dorado_bin)) {
          add_log("Downloading Dorado binary for macOS...")
          dir.create(dorado_host_dir, recursive = TRUE, showWarnings = FALSE)

          dorado_url <- sprintf("https://cdn.oxfordnanoportal.com/software/analysis/dorado-1.3.1-%s.zip", host_platform)
          dorado_archive <- file.path(dorado_host_dir, "dorado.zip")

          tryCatch({
            download.file(dorado_url, dorado_archive, mode = "wb", quiet = TRUE)
            add_log("Extracting Dorado...")
            unzip(dorado_archive, exdir = dorado_host_dir)
            unlink(dorado_archive)

            extracted_dirs <- list.dirs(dorado_host_dir, full.names = TRUE, recursive = FALSE)
            if (length(extracted_dirs) == 1 && basename(extracted_dirs[1]) != "bin") {
              contents <- list.files(extracted_dirs[1], full.names = TRUE)
              for (item in contents) {
                dest_item <- file.path(dorado_host_dir, basename(item))
                if (!file.exists(dest_item)) file.rename(item, dest_item)
              }
              unlink(extracted_dirs[1], recursive = TRUE)
            }

            if (file.exists(dorado_bin)) {
              Sys.chmod(dorado_bin, "0755")
              add_log(sprintf("✓ Dorado binary ready: %s", dorado_bin))
            }
          }, error = function(e) {
            add_log(sprintf("✗ Failed to download Dorado: %s", e$message), "error")
            dorado_bin <<- NULL
          })
        } else {
          add_log("Dorado binary already present")
        }
      } else if (sysname == "Linux") {
        platform_str <- ifelse(machine %in% c("x86_64", "amd64"), "linux-x64", "linux-arm64")
        dorado_dir <- file.path(tools_dir, "dorado")
        dorado_bin <- file.path(dorado_dir, "bin", "dorado")

        if (!file.exists(dorado_bin)) {
          add_log("Downloading Dorado binary for Linux...")
          dir.create(dorado_dir, recursive = TRUE, showWarnings = FALSE)

          dorado_url <- sprintf("https://cdn.oxfordnanoportal.com/software/analysis/dorado-1.3.1-%s.tar.gz", platform_str)
          dorado_archive <- file.path(dorado_dir, "dorado.tar.gz")

          tryCatch({
            download.file(dorado_url, dorado_archive, mode = "wb", quiet = TRUE)
            add_log("Extracting Dorado...")
            system(sprintf("cd '%s' && tar xzf dorado.tar.gz", dorado_dir))
            unlink(dorado_archive)

            if (file.exists(dorado_bin)) {
              Sys.chmod(dorado_bin, "0755")
              add_log(sprintf("✓ Dorado binary ready: %s", dorado_bin))
            }
          }, error = function(e) {
            add_log(sprintf("✗ Failed to download Dorado: %s", e$message), "error")
            dorado_bin <<- NULL
          })
        } else {
          add_log("Dorado binary already present")
        }
      }

      add_log("")

      if (!is.null(dorado_bin) && file.exists(dorado_bin)) {
        for (idx in selected_models) {
          current <- current + 1
          model <- DORADO_MODELS[[idx]]
          update_progress(round((current / total_items) * 100), sprintf("Installing %s (%d/%d)", model$name, current, total_items))
          add_log(sprintf("Installing: %s", model$name))

          model_path <- file.path(models_dir, model$id)
          if (dir.exists(model_path) && length(list.files(model_path, recursive = TRUE)) > 5) {
            add_log(sprintf("%s already installed", model$name), "success")
            success_count <- success_count + 1
            add_log("")
            next
          }

          add_log(sprintf("Downloading model: %s", model$id))
          start_time <- Sys.time()

          cmd <- sprintf("'%s' download --model %s --models-directory '%s' 2>&1", dorado_bin, model$id, models_dir)
          result <- system(cmd, wait = TRUE)
          elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

          if (result == 0 && dir.exists(model_path) && length(list.files(model_path, recursive = TRUE)) > 5) {
            add_log(sprintf("✓ %s installed (%.1fs)", model$name, elapsed), "success")
            add_log(sprintf("Model path: %s", model_path))
            success_count <- success_count + 1
          } else {
            add_log(sprintf("✗ %s failed (exit %d, %.1fs)", model$name, result, elapsed), "error")
            failed_items <- c(failed_items, model$name)
          }
          add_log("")
        }
      } else {
        add_log("✗ Dorado binary not available - skipping model downloads", "error")
        for (idx in selected_models) {
          failed_items <- c(failed_items, DORADO_MODELS[[idx]]$name)
        }
        add_log("")
      }
    }

    update_progress(100, "Installation complete")
    add_log("=== Installation Summary ===")
    add_log(sprintf("Succeeded: %d / %d", success_count, total_items))
    if (length(failed_items) > 0) {
      add_log(sprintf("Failed: %d items", length(failed_items)), "error")
      for (item in failed_items) {
        add_log(sprintf("  - %s", item), "error")
      }
    }
    add_log("")

    if (length(failed_items) == 0) {
      add_log("All items installed successfully!")
      add_log("Creating setup marker...")
      writeLines(format(Sys.time()), setup_marker_file)
      add_log(sprintf("Marker created: %s", basename(setup_marker_file)), "success")
      add_log("")
      add_log("Launching main application in 3 seconds...")
      Sys.sleep(3)
      stopApp(returnValue = "complete")
    } else {
      add_log("✗ Setup incomplete - some items failed", "error")
      add_log("Fix issues and re-run setup, or skip and configure manually", "error")
      enable("skip_setup")
    }
  })
}

shinyApp(ui, server, options = list(host = "0.0.0.0", port = 3838))
