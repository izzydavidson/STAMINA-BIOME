#!/usr/bin/env Rscript
# =============================================================================
# frontend_postprocess.R
# Frontend postprocess hook — runs after stamina_biome_run.sh exits 0.
# Called by frontend/run_with_postprocess.sh. Does NOT modify main/ or cli/.
#
# Works for all pipeline types: sr_amp, sr_meta, lr_amp, lr_meta
#
# Gaps filled:
#   G1a/b. FastQC HTML promoted to results/qc/fastqc/ and final/qc/fastqc/
#   G2.    Piechart re-run (all pipelines: sr_amp, sr_meta, lr_amp, lr_meta)
#   G3a.   Valencia R visualisation fallback (all pipelines)
#   G3b.   Abundance tables fallback via results_csv.R (sr_amp only)
#   G4.    results/tables   -> final/tables
#   G5.    results/valencia -> final/valencia
#   G5b.   valencia_cst_collate.py  (all pipelines with valencia output)
#   G5c.   plot_valencia_cst_sweep.R (gracefully exits for single-param runs)
#   G6.    Fixed piechart  -> final/plots
#   G7.    Rewrite final/manifest.json with correct counts
# =============================================================================

suppressPackageStartupMessages({
  if (requireNamespace("jsonlite", quietly = TRUE)) library(jsonlite)
})

log_msg <- function(...) cat("[POSTPROCESS]", ..., "\n")

# ---------------------------------------------------------------------------
# Resolve repo_root from script location
# ---------------------------------------------------------------------------
script_path <- tryCatch({
  arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(arg) > 0) normalizePath(sub("^--file=", "", arg[1])) else NULL
}, error = function(e) NULL)

if (!is.null(script_path)) {
  # frontend/pipelines/postprocess/r/ -> up 4 levels -> repo root
  repo_root <- normalizePath(file.path(dirname(script_path), "..", "..", "..", ".."))
} else {
  repo_root <- normalizePath(file.path(getwd(), ".."))
}
log_msg("repo_root:", repo_root)

# ---------------------------------------------------------------------------
# Parse --config argument
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
config_file <- NULL
i <- 1
while (i <= length(args)) {
  if (args[i] == "--config" && i < length(args)) {
    config_file <- args[i + 1]; i <- i + 2
  } else { i <- i + 1 }
}

if (is.null(config_file) || !file.exists(config_file)) {
  log_msg("No valid --config provided. Skipping.")
  quit(status = 0)
}

config <- tryCatch(jsonlite::fromJSON(config_file), error = function(e) {
  log_msg("Failed to parse config:", e$message); NULL
})
if (is.null(config)) quit(status = 0)

pipeline_key   <- config$pipeline_id
output_dir     <- config$run$work_dir
run_id_raw     <- config$run$run_id

# Sanitize run_id the same way pipeline_modal_server.R does
sanitized_run_id <- tolower(run_id_raw)
sanitized_run_id <- gsub("[^a-z0-9_-]", "", sanitized_run_id)
sanitized_run_id <- gsub("^-+|-+$",     "", sanitized_run_id)

run_dir      <- file.path(output_dir, sanitized_run_id)
module_dir   <- file.path(run_dir, pipeline_key)
outputs_json <- file.path(module_dir, "outputs.json")
results_dir  <- file.path(run_dir, "results")
final_dir    <- file.path(run_dir, "final_results")

# QIIME2-based pipelines use amplicon short-read or short-read meta
is_qiime2_pipeline <- pipeline_key %in% c("sr_amp", "sr_meta")

log_msg("=== Starting frontend postprocess ===")
log_msg("  run_dir:      ", run_dir)
log_msg("  pipeline_key: ", pipeline_key)
log_msg("  is_qiime2:    ", is_qiime2_pipeline)
log_msg("  outputs_json: ", outputs_json)
log_msg("  results_dir:  ", results_dir)
log_msg("  final_dir:    ", final_dir)

# ---------------------------------------------------------------------------
# Helper: copy files with explicit per-file logging
# ---------------------------------------------------------------------------
copy_files <- function(src_files, dst_dir, label) {
  if (length(src_files) == 0) {
    log_msg(label, ": no files to copy")
    return(invisible(0))
  }
  dir.create(dst_dir, recursive = TRUE, showWarnings = FALSE)
  n_ok <- 0
  for (f in src_files) {
    dest <- file.path(dst_dir, basename(f))
    ok   <- file.copy(f, dest, overwrite = TRUE)
    if (ok) {
      log_msg(label, ": copied", basename(f), "->", dst_dir)
      n_ok <- n_ok + 1
    } else {
      log_msg(label, ": FAILED to copy", basename(f))
    }
  }
  log_msg(label, ":", n_ok, "/", length(src_files), "file(s) copied")
  invisible(n_ok)
}

# ---------------------------------------------------------------------------
# G0. Apply sample_map: rename barcode* sample IDs -> user-defined names
# Runs a host-side Python script that rewrites sample_id values in all
# postprocess tidy CSVs and output CSVs before the R plot scripts are
# re-invoked.  Only active when config contains a sample_map.
# ---------------------------------------------------------------------------
log_msg("--- G0: Apply sample_map renaming (if configured) ---")
if (!is.null(config$sample_map) && length(config$sample_map) > 0) {
  apply_map_script <- file.path(repo_root, "frontend", "pipelines", "postprocess",
                                "python", "apply_sample_map.py")
  if (file.exists(apply_map_script)) {
    apply_map_log <- file.path(module_dir, "logs", "r_postprocess", "apply_sample_map.log")
    dir.create(dirname(apply_map_log), recursive = TRUE, showWarnings = FALSE)
    rc_map <- tryCatch(
      system2("python3", args = c(apply_map_script, "--config", config_file),
              stdout = apply_map_log, stderr = apply_map_log, wait = TRUE),
      error = function(e) { log_msg("apply_sample_map.py error:", e$message); -1L }
    )
    log_msg("apply_sample_map.py exit code:", rc_map)
    if (file.exists(apply_map_log))
      log_msg(paste(readLines(apply_map_log), collapse = "\n"))
  } else {
    log_msg("apply_sample_map.py not found at:", apply_map_script)
  }
} else {
  log_msg("No sample_map in config — skipping renaming")
}

# ---------------------------------------------------------------------------
# G1a. FastQC HTML -> results/qc/fastqc/
# ---------------------------------------------------------------------------
fastqc_src <- file.path(module_dir, "results", "fastqc")
fastqc_dst <- file.path(results_dir, "qc", "fastqc")

log_msg("--- G1a: FastQC -> results/qc/fastqc/ ---")
if (dir.exists(fastqc_src)) {
  fqc_html <- list.files(fastqc_src, pattern = "\\.html$", full.names = TRUE)
  copy_files(fqc_html, fastqc_dst, "FastQC->results/qc/fastqc")
} else {
  log_msg("FastQC source not found:", fastqc_src)
}

# ---------------------------------------------------------------------------
# G2. Re-run fixed piechart -> results/plots/
# All pipelines: main's piechart.R puts legend on a new page when the grid
# is exactly full.  The fixed frontend piechart.R allocates n_samples+1
# grid slots so the legend always shares the same page as the pie charts.
#
# NOTE: processx::run() with 90-second timeout prevents deadlock from
# nested R subprocess library lock contention on macOS.
# ---------------------------------------------------------------------------
log_msg("--- G2: Re-run fixed piechart (all pipelines) ---")
if (file.exists(outputs_json)) {
  plots_dir <- file.path(results_dir, "plots")
  dir.create(plots_dir, recursive = TRUE, showWarnings = FALSE)

  frontend_piechart <- file.path(repo_root, "frontend", "pipelines", "postprocess", "r", "piechart.R")
  if (file.exists(frontend_piechart)) {
    piechart_log <- file.path(module_dir, "logs", "r_postprocess", "piechart_fixed.log")
    dir.create(dirname(piechart_log), recursive = TRUE, showWarnings = FALSE)

    piechart_params_json <- tryCatch({
      step <- config$postprocess$steps$piechart
      if (is.list(step) && !is.null(step$params)) {
        jsonlite::toJSON(step$params, auto_unbox = TRUE)
      } else "{}"
    }, error = function(e) "{}")
    log_msg("G2: piechart params_json:", piechart_params_json)

    piechart_args <- c(frontend_piechart,
                       "--outputs_json", outputs_json,
                       "--out_dir",      plots_dir,
                       "--params_json",  piechart_params_json,
                       "--module",       pipeline_key)

    rc <- tryCatch({
      if (requireNamespace("processx", quietly = TRUE)) {
        result <- processx::run(
          "Rscript", piechart_args,
          stdout = piechart_log, stderr = piechart_log,
          timeout = 90, error_on_status = FALSE
        )
        result$status
      } else {
        system2("Rscript", args = piechart_args,
                stdout = piechart_log, stderr = piechart_log, wait = TRUE)
      }
    }, error = function(e) {
      log_msg("Piechart timed out or errored:", e$message, "- continuing")
      -1L
    })
    log_msg("Piechart exit code:", rc)
  } else {
    log_msg("Frontend piechart.R not found at:", frontend_piechart)
  }
} else {
  log_msg("outputs.json not found; skipping piechart re-run")
}

# ---------------------------------------------------------------------------
# G2b. Re-run heatmap, stacked_bar, results_csv from HOST using renamed data.
# Only runs when sample_map is configured — regenerates plots so sample labels
# in PNGs/PDFs match the user-defined names applied in G0.
# Calls the unmodified main/ R scripts; graceful failure if packages missing.
# ---------------------------------------------------------------------------
log_msg("--- G2b: Re-run R plot scripts with renamed data (sample_map only) ---")
if (!is.null(config$sample_map) && length(config$sample_map) > 0 &&
    file.exists(outputs_json)) {

  plots_dir_g2b  <- file.path(results_dir, "plots")
  tables_dir_g2b <- file.path(results_dir, "tables")
  dir.create(plots_dir_g2b,  recursive = TRUE, showWarnings = FALSE)
  dir.create(tables_dir_g2b, recursive = TRUE, showWarnings = FALSE)

  rerun_scripts <- list(
    list(script = "heatmap.R",     out = plots_dir_g2b),
    list(script = "stacked_bar.R", out = plots_dir_g2b),
    list(script = "results_csv.R", out = tables_dir_g2b)
  )

  for (item in rerun_scripts) {
    script_path <- file.path(repo_root, "main", "pipelines", "postprocess", "r", item$script)
    if (!file.exists(script_path)) {
      log_msg(item$script, "not found — skipping")
      next
    }
    rr_log <- file.path(module_dir, "logs", "r_postprocess",
                        paste0(sub("\\.R$", "", item$script), "_rerun.log"))
    dir.create(dirname(rr_log), recursive = TRUE, showWarnings = FALSE)

    rc_rr <- tryCatch({
      if (requireNamespace("processx", quietly = TRUE)) {
        res <- processx::run(
          "Rscript",
          c(script_path,
            "--outputs_json", outputs_json,
            "--out_dir",      item$out,
            "--params_json",  "{}",
            "--module",       pipeline_key),
          stdout = rr_log, stderr = rr_log,
          timeout = 120, error_on_status = FALSE
        )
        res$status
      } else {
        system2("Rscript",
                args   = c(script_path,
                           "--outputs_json", outputs_json,
                           "--out_dir",      item$out,
                           "--params_json",  "{}",
                           "--module",       pipeline_key),
                stdout = rr_log, stderr = rr_log, wait = TRUE)
      }
    }, error = function(e) {
      log_msg(item$script, "re-run error:", e$message)
      -1L
    })
    log_msg(item$script, "re-run exit code:", rc_rr)
  }
} else {
  log_msg("No sample_map or no outputs.json — skipping R plot re-runs")
}

# ---------------------------------------------------------------------------
# G3a. Valencia R visualizations fallback (all pipelines)
# Run if pipeline produced a VALENCIA output CSV but PNG plots are missing.
# ---------------------------------------------------------------------------
log_msg("--- G3a: Valencia visualizations fallback ---")
valencia_src_candidates <- c(
  file.path(module_dir, "results", "valencia", "output.csv"),
  file.path(module_dir, "results", "valencia", "valencia_assignments.csv")
)
valencia_results_dst <- file.path(results_dir, "valencia")
has_png <- dir.exists(valencia_results_dst) &&
  length(list.files(valencia_results_dst, pattern = "\\.png$")) > 0

if (!has_png) {
  found_csv <- Filter(file.exists, valencia_src_candidates)
  if (length(found_csv) > 0 && file.exists(outputs_json)) {
    main_valencia <- file.path(repo_root, "main", "pipelines", "postprocess", "r", "valencia.R")
    if (file.exists(main_valencia)) {
      dir.create(valencia_results_dst, recursive = TRUE, showWarnings = FALSE)
      log_msg("Running VALENCIA R visualizations (fallback)")
      valencia_log <- file.path(module_dir, "logs", "r_postprocess", "valencia_fallback.log")
      dir.create(dirname(valencia_log), recursive = TRUE, showWarnings = FALSE)
      system2("Rscript",
              args   = c(main_valencia,
                         "--outputs_json", outputs_json,
                         "--out_dir",      valencia_results_dst,
                         "--module",       pipeline_key),
              stdout = valencia_log, stderr = valencia_log, wait = TRUE)
      log_msg("Valencia fallback complete ->", valencia_results_dst)
    } else {
      log_msg("main/valencia.R not found:", main_valencia)
    }
  } else {
    log_msg("No VALENCIA CSV found or no outputs.json; skipping valencia fallback")
  }
} else {
  log_msg("Valencia PNGs already present; skipping fallback")
}

# ---------------------------------------------------------------------------
# G3b. Abundance tables fallback via results_csv.R (sr_amp only)
# ---------------------------------------------------------------------------
log_msg("--- G3b: Abundance tables fallback (sr_amp only) ---")
tables_results_dst <- file.path(results_dir, "tables")
tables_file        <- file.path(tables_results_dst, "results.csv")
tables_missing     <- !file.exists(tables_file) ||
  file.info(tables_file)$size < 100

if (pipeline_key == "sr_amp" && tables_missing && file.exists(outputs_json)) {
  main_results_csv <- file.path(repo_root, "main", "pipelines", "postprocess", "r", "results_csv.R")
  if (file.exists(main_results_csv)) {
    dir.create(tables_results_dst, recursive = TRUE, showWarnings = FALSE)
    log_msg("Running results_csv.R (tables fallback)")
    tables_log <- file.path(module_dir, "logs", "r_postprocess", "results_csv_fallback.log")
    dir.create(dirname(tables_log), recursive = TRUE, showWarnings = FALSE)
    rc <- system2("Rscript",
                  args   = c(main_results_csv,
                             "--outputs_json", outputs_json,
                             "--out_dir",      tables_results_dst,
                             "--module",       pipeline_key),
                  stdout = tables_log, stderr = tables_log, wait = TRUE)
    log_msg("results_csv exit code:", rc)
  } else {
    log_msg("main/results_csv.R not found:", main_results_csv)
  }
} else if (pipeline_key != "sr_amp") {
  log_msg("Skipping QIIME2 results_csv fallback for non-sr_amp pipeline:", pipeline_key)
} else {
  log_msg("Tables already present or no outputs.json; skipping fallback")
}

# ---------------------------------------------------------------------------
# G4. Mirror results/tables -> final/tables  (main never does this for sr_amp)
# Also pull CSV data files that main wrote into results/plots/ (heatmap_*_data.csv,
# piechart_*_data.csv, etc.) — they belong in tables/, not plots/.
# ---------------------------------------------------------------------------
log_msg("--- G4: Mirror results/tables -> final/tables/ ---")
tables_all <- list.files(tables_results_dst, full.names = TRUE)

# Grab any *_data.csv files sitting in results/plots/ and add them to tables
plots_data_csvs <- list.files(file.path(results_dir, "plots"),
                               pattern = "\\.(csv|tsv)$", full.names = TRUE)
if (length(plots_data_csvs) > 0) {
  log_msg("G4: Moving", length(plots_data_csvs), "data CSV(s) from results/plots/ -> final/tables/")
}
tables_all_incl <- unique(c(tables_all, plots_data_csvs))
copy_files(tables_all_incl, file.path(final_dir, "tables"), "tables->final")

# ---------------------------------------------------------------------------
# G5. Mirror results/valencia -> final/valencia  (main never does this)
# ---------------------------------------------------------------------------
log_msg("--- G5: Mirror results/valencia -> final/valencia/ ---")
if (dir.exists(valencia_results_dst)) {
  valencia_all <- list.files(valencia_results_dst, full.names = TRUE)
  copy_files(valencia_all, file.path(final_dir, "valencia"), "valencia->final")
} else {
  log_msg("No results/valencia/ directory; skipping")
}

# ---------------------------------------------------------------------------
# G5b. Run valencia_cst_collate.py to generate aggregate CST tables.
# For single runs: renames output.csv -> <run_id>_1param_valencia_out.csv
# in a staging directory so collate can find it by name convention.
# Collate outputs (*_long.csv, *_counts.csv, *_proportions.csv) are copied
# to both results/valencia/ and final/valencia/.
# ---------------------------------------------------------------------------
log_msg("--- G5b: VALENCIA CST collate ---")

valencia_main_csv <- Filter(file.exists, c(
  file.path(results_dir, "valencia", "output.csv"),
  file.path(results_dir, "valencia", "valencia_assignments.csv"),
  file.path(module_dir, "results", "valencia", "output.csv"),
  file.path(module_dir, "results", "valencia", "valencia_assignments.csv")
))

collate_script <- file.path(repo_root, "main", "pipelines", "postprocess", "valencia_cst_collate.py")

if (length(valencia_main_csv) > 0 && file.exists(collate_script)) {
  # Create a staging directory with the expected naming convention
  collate_staging <- file.path(run_dir, ".valencia_collate_staging")
  dir.create(collate_staging, recursive = TRUE, showWarnings = FALSE)

  # Name the file so collate can parse it: <run_base>_1param_valencia_out.csv
  staged_csv <- file.path(collate_staging,
                           paste0(sanitized_run_id, "_1param_valencia_out.csv"))
  file.copy(valencia_main_csv[1], staged_csv, overwrite = TRUE)

  collate_log <- file.path(module_dir, "logs", "r_postprocess", "valencia_collate.log")
  dir.create(dirname(collate_log), recursive = TRUE, showWarnings = FALSE)

  log_msg("Running valencia_cst_collate.py with staged CSV:", staged_csv)
  collate_rc <- tryCatch({
    system2("python3",
            args   = c(collate_script, collate_staging, sanitized_run_id),
            stdout = collate_log, stderr = collate_log, wait = TRUE)
  }, error = function(e) {
    log_msg("valencia_cst_collate.py error:", e$message)
    -1L
  })
  log_msg("valencia_cst_collate.py exit code:", collate_rc)

  if (collate_rc == 0) {
    # Copy collate outputs to results/valencia/ and final/valencia/
    collate_outputs <- list.files(collate_staging,
                                   pattern = paste0("^", sanitized_run_id),
                                   full.names = TRUE)
    collate_outputs <- collate_outputs[!grepl("_1param_valencia_out\\.csv$", collate_outputs)]

    if (length(collate_outputs) > 0) {
      dir.create(file.path(results_dir, "valencia"), recursive = TRUE, showWarnings = FALSE)
      dir.create(file.path(final_dir, "valencia"),   recursive = TRUE, showWarnings = FALSE)
      copy_files(collate_outputs, file.path(results_dir, "valencia"), "collate->results/valencia")
      copy_files(collate_outputs, file.path(final_dir, "valencia"),   "collate->final/valencia")
    } else {
      log_msg("No collate output files found in staging dir")
    }
  }

  # ---------------------------------------------------------------------------
  # G5c. Run plot_valencia_cst_sweep.R (gracefully exits if n_params <= 1)
  # ---------------------------------------------------------------------------
  log_msg("--- G5c: plot_valencia_cst_sweep.R (single-param graceful exit OK) ---")
  sweep_script <- file.path(repo_root, "main", "pipelines", "postprocess", "plot_valencia_cst_sweep.R")
  prop_csv <- file.path(collate_staging,
                         paste0(sanitized_run_id, "_valencia_cst_proportions_by_param.csv"))

  if (file.exists(sweep_script) && file.exists(prop_csv)) {
    sweep_log <- file.path(module_dir, "logs", "r_postprocess", "valencia_sweep.log")
    dir.create(dirname(sweep_log), recursive = TRUE, showWarnings = FALSE)

    sweep_rc <- tryCatch({
      if (requireNamespace("processx", quietly = TRUE)) {
        result <- processx::run(
          "Rscript", c(sweep_script, collate_staging, sanitized_run_id),
          stdout = sweep_log, stderr = sweep_log,
          timeout = 120, error_on_status = FALSE
        )
        result$status
      } else {
        system2("Rscript",
                args   = c(sweep_script, collate_staging, sanitized_run_id),
                stdout = sweep_log, stderr = sweep_log, wait = TRUE)
      }
    }, error = function(e) {
      log_msg("plot_valencia_cst_sweep.R error:", e$message)
      -1L
    })
    log_msg("plot_valencia_cst_sweep.R exit code:", sweep_rc)

    # Copy any sweep plots generated (only present if n_params > 1)
    sweep_plots <- list.files(collate_staging, pattern = "\\.png$", full.names = TRUE)
    if (length(sweep_plots) > 0) {
      dir.create(file.path(results_dir, "plots"), recursive = TRUE, showWarnings = FALSE)
      dir.create(file.path(final_dir,   "plots"), recursive = TRUE, showWarnings = FALSE)
      copy_files(sweep_plots, file.path(results_dir, "plots"), "sweep_plot->results/plots")
      copy_files(sweep_plots, file.path(final_dir,   "plots"), "sweep_plot->final/plots")
    } else {
      log_msg("No sweep plots generated (expected for single-param runs)")
    }
  } else if (!file.exists(sweep_script)) {
    log_msg("plot_valencia_cst_sweep.R not found:", sweep_script)
  } else {
    log_msg("Proportions CSV not found; skipping sweep plot")
  }
} else if (!file.exists(collate_script)) {
  log_msg("valencia_cst_collate.py not found:", collate_script)
} else {
  log_msg("No VALENCIA output CSV found in results/; skipping collate")
}

# ---------------------------------------------------------------------------
# G6. Copy ALL plot images (png/pdf/svg) from results/plots/ -> final/plots/
# Images only — CSV data files were already routed to final/tables/ in G4.
# Also purge any CSV/TSV files that earlier syncs may have put in final/plots/.
# ---------------------------------------------------------------------------
log_msg("--- G6: Plot images -> final/plots/ ---")
all_plot_imgs <- list.files(file.path(results_dir, "plots"),
                             pattern = "\\.(png|pdf|svg)$", full.names = TRUE)
if (length(all_plot_imgs) > 0) {
  copy_files(all_plot_imgs, file.path(final_dir, "plots"), "plots->final/plots")
} else {
  log_msg("No plot images found in results/plots/; skipping")
}

# Purge any CSV/TSV data files that ended up in final/plots/ (from earlier syncs)
stale_csvs <- list.files(file.path(final_dir, "plots"),
                          pattern = "\\.(csv|tsv)$", full.names = TRUE)
if (length(stale_csvs) > 0) {
  file.remove(stale_csvs)
  log_msg("G6: Removed", length(stale_csvs), "stale CSV(s) from final/plots/:",
          paste(basename(stale_csvs), collapse = ", "))
}

# ---------------------------------------------------------------------------
# G1b. FastQC HTML -> final/qc/fastqc
# Look in both the promoted results/qc/fastqc/ and the original
# <module>/results/fastqc/ location.  The main pipeline never promotes
# FastQC HTML to final/qc/, so we always need to do this explicitly.
# ---------------------------------------------------------------------------
log_msg("--- G1b: FastQC -> final/qc/fastqc/ ---")
fqc_sources <- unique(c(
  if (dir.exists(fastqc_dst))
    list.files(fastqc_dst, pattern = "\\.html$", full.names = TRUE)
  else character(0),
  # original module-level fastqc dir (always present after fastqc step)
  list.files(fastqc_src, pattern = "\\.html$", full.names = TRUE)
))
if (length(fqc_sources) > 0) {
  copy_files(fqc_sources, file.path(final_dir, "qc", "fastqc"), "FastQC->final/qc/fastqc")
} else {
  log_msg("No FastQC HTML files found; skipping FastQC->final copy")
}

# Also copy multiqc from results/qc/ -> final/qc/ (in case bash layer missed it)
multiqc_src_files <- list.files(file.path(results_dir, "qc"),
                                  pattern = "\\.html$", full.names = TRUE, recursive = FALSE)
if (length(multiqc_src_files) > 0) {
  copy_files(multiqc_src_files, file.path(final_dir, "qc"), "multiqc->final/qc")
}

# ---------------------------------------------------------------------------
# G7. Rewrite final/manifest.json with correct counts
# Main wrote it before G4/G5 populated final/tables & final/valencia.
# ---------------------------------------------------------------------------
log_msg("--- G7: Rewrite final/manifest.json ---")
final_plots_files    <- list.files(file.path(final_dir, "plots"),   full.names = FALSE)
final_tables_files   <- list.files(file.path(final_dir, "tables"),  full.names = FALSE)
final_valencia_files <- list.files(file.path(final_dir, "valencia"), full.names = FALSE)

# QC: combine both multiqc root and fastqc/ subdir
final_qc_subdir <- list.files(file.path(final_dir, "qc"),
                               full.names = TRUE, recursive = TRUE)
final_qc_files  <- basename(final_qc_subdir)

manifest <- list(
  run_name = sanitized_run_id,
  pipeline = pipeline_key,
  outputs  = list(
    tables   = as.list(final_tables_files),
    plots    = as.list(final_plots_files),
    valencia = as.list(final_valencia_files),
    qc       = as.list(final_qc_files)
  ),
  summary  = list(
    plots_count    = length(final_plots_files),
    tables_count   = length(final_tables_files),
    valencia_count = length(final_valencia_files),
    qc_count       = length(final_qc_files)
  )
)

manifest_path <- file.path(final_dir, "manifest.json")
tryCatch({
  jsonlite::write_json(manifest, manifest_path, pretty = TRUE, auto_unbox = TRUE)
  log_msg("Wrote", manifest_path)
}, error = function(e) {
  log_msg("Failed to write manifest:", e$message)
})

# ---------------------------------------------------------------------------
# Verification: compare results/ vs final/ counts
# ---------------------------------------------------------------------------
log_msg("=== VERIFICATION ===")

count_files <- function(dir, pattern = NULL, recursive = FALSE) {
  if (!dir.exists(dir)) return(0)
  files <- list.files(dir, full.names = FALSE, recursive = recursive)
  if (!is.null(pattern)) files <- grep(pattern, files, value = TRUE)
  length(files)
}

r_plots    <- count_files(file.path(results_dir, "plots"),   "\\.(png|pdf)$")
r_tables   <- count_files(file.path(results_dir, "tables"),  "\\.(csv|tsv|json)$")
r_valencia <- count_files(file.path(results_dir, "valencia"))
r_qc       <- count_files(file.path(results_dir, "qc"), recursive = TRUE)

f_plots    <- count_files(file.path(final_dir, "plots"),   "\\.(png|pdf)$")
f_tables   <- count_files(file.path(final_dir, "tables"),  "\\.(csv|tsv|json)$")
f_valencia <- count_files(file.path(final_dir, "valencia"))
f_qc       <- count_files(file.path(final_dir, "qc"), recursive = TRUE)

log_msg(sprintf("  plots   : results/=%d  final/=%d  %s",
                r_plots,    f_plots,    if (f_plots    > 0) "OK" else "MISSING"))
log_msg(sprintf("  tables  : results/=%d  final/=%d  %s",
                r_tables,   f_tables,   if (f_tables   > 0) "OK" else "MISSING"))
log_msg(sprintf("  valencia: results/=%d  final/=%d  %s",
                r_valencia, f_valencia, if (f_valencia  > 0) "OK" else "MISSING"))
log_msg(sprintf("  qc      : results/=%d  final/=%d  %s",
                r_qc,       f_qc,       if (f_qc       > 0) "OK" else "MISSING"))

log_msg("=== Frontend postprocess complete ===")
