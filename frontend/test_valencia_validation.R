#!/usr/bin/env Rscript

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  setwd(dirname(normalizePath(sys.frame(1)$ofile, mustWork = FALSE)))
}
source("utils/config_generator.R")

cat("\n========== VALENCIA VALIDATION TEST ==========\n\n")

repo_root <- dirname(getwd())

cat("Test 1: VALENCIA enabled with centroids present\n")
cat("------------------------------------------------\n")

test_params_1 <- list(
  run_id = "test_valencia_enabled",
  pipeline = "sr_amp",
  technology = "illumina",
  sample_type = "vaginal",
  paired_end = TRUE,
  input_r1 = "/path/to/r1.fastq",
  input_r2 = "/path/to/r2.fastq",
  output_dir = file.path(repo_root, "outputs"),
  quality_threshold = 20,
  min_read_length = 50,
  threads = 4,
  dada2_trunc_f = 220,
  dada2_trunc_r = 200,
  valencia = "yes",
  output_selected = c("all")
)

config_1 <- generate_sr_amp_config(test_params_1)
validation_1 <- validate_dependencies(config_1)

cat("\nConfig valencia section:\n")
print(config_1$valencia)

cat("\nValidation result:\n")
cat("  Valid:", validation_1$valid, "\n")
cat("  Errors:", if (length(validation_1$errors) == 0) "none" else paste(validation_1$errors, collapse = "; "), "\n")
cat("  Warnings:", if (length(validation_1$warnings) == 0) "none" else paste(validation_1$warnings, collapse = "; "), "\n")

cat("\n\nTest 2: VALENCIA disabled\n")
cat("-------------------------\n")

test_params_2 <- test_params_1
test_params_2$valencia <- "no"

config_2 <- generate_sr_amp_config(test_params_2)
validation_2 <- validate_dependencies(config_2)

cat("\nConfig valencia section:\n")
print(config_2$valencia)

cat("\nValidation result:\n")
cat("  Valid:", validation_2$valid, "\n")
cat("  Errors:", if (length(validation_2$errors) == 0) "none" else paste(validation_2$errors, collapse = "; "), "\n")

cat("\n\nTest 3: Non-vaginal sample (no VALENCIA)\n")
cat("----------------------------------------\n")

test_params_3 <- test_params_1
test_params_3$sample_type <- "gut"

config_3 <- generate_sr_amp_config(test_params_3)
validation_3 <- validate_dependencies(config_3)

cat("\nConfig has valencia section:", !is.null(config_3$valencia), "\n")

cat("\nValidation result:\n")
cat("  Valid:", validation_3$valid, "\n")
cat("  Errors:", if (length(validation_3$errors) == 0) "none" else paste(validation_3$errors, collapse = "; "), "\n")

cat("\n\nTest 4: VALENCIA enabled but centroids missing (simulated)\n")
cat("----------------------------------------------------------\n")

config_4 <- config_1
config_4$valencia$centroids_csv <- "/nonexistent/path/CST_centroids_012920.csv"

validation_4 <- validate_dependencies(config_4)

cat("\nConfig valencia.centroids_csv:", config_4$valencia$centroids_csv, "\n")

cat("\nValidation result:\n")
cat("  Valid:", validation_4$valid, "\n")
cat("  Errors:", if (length(validation_4$errors) == 0) "none" else "\n    - ", paste(validation_4$errors, collapse = "\n    - "), "\n")

cat("\n\nTest 5: Check SILVA classifier detection\n")
cat("-----------------------------------------\n")

classifier_path <- file.path(repo_root, "main", "data", "reference", "qiime2", "silva-138-99-nb-classifier.qza")
cat("SILVA classifier path:", classifier_path, "\n")
cat("Exists:", file.exists(classifier_path), "\n")

config_5 <- generate_sr_amp_config(test_params_3)
cat("\nConfig qiime2.classifier.qza:", config_5$qiime2$classifier$qza, "\n")

validation_5 <- validate_dependencies(config_5)
cat("\nValidation result:\n")
cat("  Valid:", validation_5$valid, "\n")
cat("  Warnings:", if (length(validation_5$warnings) == 0) "none" else paste(validation_5$warnings, collapse = "; "), "\n")

cat("\n========== TEST COMPLETE ==========\n")
