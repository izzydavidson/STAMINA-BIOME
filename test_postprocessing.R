#!/usr/bin/env Rscript
# Test script to verify post-processing works correctly

library(jsonlite)
library(processx)

cat("\n")
cat("==============================================\n")
cat("  Testing Post-Processing Fix\n")
cat("==============================================\n\n")

# Setup paths
repo_root <- file.path(dirname(normalizePath(sys.frame(1)$ofile, mustWork = FALSE)), "main")
work_dir <- path.expand("~/Desktop")
run_id <- "Short_Read_Pipeline"
run_dir <- file.path(work_dir, run_id)

# Create config matching user's exact parameters
config <- list(
  pipeline_id = "sr_amp",
  technology = "ILLUMINA",
  sample_type = "vaginal",
  run = list(
    work_dir = work_dir,
    run_id = run_id,
    run_dir = run_dir,
    force_overwrite = 1
  ),
  input = list(
    style = "FASTQ_SINGLE",
    sample_type = "vaginal",
    fastq_r1 = file.path(run_dir, "input_files/ERR10233589_1.fastq")
  ),
  resources = list(threads = 4),
  params = list(
    common = list(
      min_qscore = 6,
      remove_host = 0
    )
  ),
  qfilter = list(enabled = 1, min_q = 6),
  output = list(
    selected = list("default"),
    finalize = 1,
    qc_in_final = 1
  ),
  postprocess = list(
    enabled = 1,
    rscript_bin = "Rscript",
    steps = list(
      heatmap = 1,
      piechart = 1,
      relative_abundance = 1,
      stacked_bar = 1,
      results_csv = 1,
      valencia = 1
    )
  ),
  qiime2 = list(
    sample_id = "sample",
    primers = list(forward = "", reverse = ""),
    classifier = list(
      qza = file.path(repo_root, "data/reference/qiime2/silva-138-99-nb-classifier.qza")
    ),
    dada2 = list(
      trim_left_f = 0,
      trim_left_r = 0,
      trunc_len_f = 150,
      trunc_len_r = 150,
      n_threads = 0
    ),
    diversity = list(
      sampling_depth = 0,
      metadata_tsv = ""
    )
  ),
  valencia = list(
    enabled = 1,
    mode = "auto",
    centroids_csv = file.path(repo_root, "../tools/VALENCIA/CST_centroids_012920.csv")
  ),
  tools = list(
    fastqc_bin = file.path(repo_root, "tools/wrappers/fastqc"),
    multiqc_bin = file.path(repo_root, "tools/wrappers/multiqc")
  ),
  host = list(resources = list())
)

# Create directories
cat("Creating run directory structure...\n")
dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(run_dir, "input_files"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(run_dir, "logs"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(run_dir, "results"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(run_dir, "qc"), recursive = TRUE, showWarnings = FALSE)

# Copy input file
input_source <- file.path(repo_root, "data/test_inputs/ERR10233589_1.fastq")
if (!file.exists(input_source)) {
  cat("ERROR: Input file not found at:", input_source, "\n")
  quit(status = 1)
}

file.copy(input_source, file.path(run_dir, "input_files/ERR10233589_1.fastq"), overwrite = TRUE)
cat("✓ Input file copied\n")

# Write config
config_file <- file.path(run_dir, "frontend_config.json")
write(toJSON(config, auto_unbox = TRUE, pretty = TRUE), config_file)
cat("✓ Config written to:", config_file, "\n\n")

# Run pipeline
cat("Running pipeline...\n")
cat("(This will take several minutes)\n\n")

runner_script <- file.path(repo_root, "pipelines/stamina_biome_run.sh")
proc <- process$new(
  command = runner_script,
  args = c("--config", config_file, "--force-overwrite"),
  stdout = "|",
  stderr = "2>&1",
  wd = repo_root,
  supervise = TRUE
)

# Stream output
while (proc$is_alive()) {
  lines <- proc$read_output_lines()
  for (line in lines) {
    if (nchar(line) > 0) cat(line, "\n")
  }
  Sys.sleep(0.2)
}

# Read remaining output
lines <- proc$read_output_lines()
for (line in lines) {
  if (nchar(line) > 0) cat(line, "\n")
}

exit_code <- proc$get_exit_status()
cat("\n")
cat("Pipeline exit code:", exit_code, "\n")

# Check steps.json
steps_file <- file.path(run_dir, "sr_amp", "steps.json")
if (file.exists(steps_file)) {
  steps <- fromJSON(steps_file)
  failed <- sum(steps$status == "failed", na.rm = TRUE)
  cat("Failed steps:", failed, "/", nrow(steps), "\n")

  if (failed == 0) {
    cat("\n✓ All pipeline steps succeeded!\n\n")

    # Run post-processing
    cat("==============================================\n")
    cat("  Running Post-Processing\n")
    cat("==============================================\n\n")

    module_dir <- file.path(run_dir, "sr_amp")
    module_outputs <- file.path(module_dir, "outputs.json")
    postprocess_script <- file.path(repo_root, "pipelines/postprocess/r/run_r_postprocess.sh")
    postprocess_log <- file.path(module_dir, "logs", "r_postprocess_runner.log")

    dir.create(dirname(postprocess_log), recursive = TRUE, showWarnings = FALSE)

    cat("Script:", postprocess_script, "\n")
    cat("Config:", config_file, "\n")
    cat("Outputs:", module_outputs, "\n")
    cat("Module: sr_amp\n")
    cat("Log:", postprocess_log, "\n\n")

    pp_proc <- process$new(
      command = postprocess_script,
      args = c("--config", config_file, "--outputs", module_outputs, "--module", "sr_amp"),
      stdout = postprocess_log,
      stderr = "2>&1",
      wd = file.path(repo_root, "pipelines"),
      supervise = TRUE
    )

    # Poll log file
    last_line_count <- 0
    while (pp_proc$is_alive()) {
      Sys.sleep(0.3)
      if (file.exists(postprocess_log)) {
        lines <- readLines(postprocess_log, warn = FALSE)
        if (length(lines) > last_line_count) {
          new_lines <- lines[(last_line_count + 1):length(lines)]
          for (line in new_lines) {
            cat("[postprocess]", line, "\n")
          }
          last_line_count <- length(lines)
        }
      }
    }

    # Read final log output
    if (file.exists(postprocess_log)) {
      lines <- readLines(postprocess_log, warn = FALSE)
      if (length(lines) > last_line_count) {
        new_lines <- lines[(last_line_count + 1):length(lines)]
        for (line in new_lines) {
          cat("[postprocess]", line, "\n")
        }
      }
    }

    pp_exit <- pp_proc$get_exit_status()
    cat("\nPost-processing exit code:", pp_exit, "\n\n")

    # Verify results
    cat("==============================================\n")
    cat("  Verification\n")
    cat("==============================================\n\n")

    final_dir <- file.path(module_dir, "final")
    if (dir.exists(final_dir)) {
      cat("✓ final/ directory created\n")

      final_plots <- file.path(final_dir, "plots")
      if (dir.exists(final_plots)) {
        plots <- list.files(final_plots, pattern = "\\.(png|pdf)$", recursive = TRUE)
        cat("✓ final/plots/ contains", length(plots), "files:\n")
        for (p in plots) {
          cat("  -", p, "\n")
        }
      } else {
        cat("✗ final/plots/ not found\n")
      }
    } else {
      cat("✗ final/ directory NOT created\n")
    }

    results_dir <- file.path(module_dir, "results")
    if (dir.exists(results_dir)) {
      cat("\n✓ results/ directory exists\n")
      results_plots <- file.path(results_dir, "plots")
      if (dir.exists(results_plots)) {
        plots <- list.files(results_plots, pattern = "\\.(png|pdf)$", recursive = TRUE)
        cat("✓ results/plots/ contains", length(plots), "files\n")
      }
    }

    cat("\n==============================================\n")
    if (dir.exists(final_dir) && length(list.files(file.path(final_dir, "plots"), pattern = "\\.(png|pdf)$")) > 0) {
      cat("  ✓✓✓ TEST PASSED ✓✓✓\n")
    } else {
      cat("  ✗✗✗ TEST FAILED ✗✗✗\n")
    }
    cat("==============================================\n\n")
  } else {
    cat("\n✗ Pipeline had", failed, "failed steps - skipping post-processing\n")
  }
} else {
  cat("✗ steps.json not found\n")
}
