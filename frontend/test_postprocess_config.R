#!/usr/bin/env Rscript

if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
} else {
  setwd(dirname(normalizePath(sys.frame(1)$ofile, mustWork = FALSE)))
}
source("utils/config_generator.R")

cat("\n========== POSTPROCESS CONFIG TEST ==========\n\n")

repo_root <- dirname(getwd())

cat("Test 1: SR_AMP with postprocess ENABLED\n")
cat("----------------------------------------\n")

test_params_1 <- list(
  run_id = "test_postprocess_enabled",
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
  enable_postprocess = TRUE,
  output_selected = c("all")
)

config_1 <- generate_sr_amp_config(test_params_1)

cat("\nGenerated postprocess section:\n")
cat("  enabled:", config_1$postprocess$enabled, "\n")
cat("  Type:", class(config_1$postprocess$enabled), "\n")
cat("  Expected: 1 (numeric integer)\n")
cat("  Result:", if (identical(config_1$postprocess$enabled, 1L)) "✅ PASS" else "❌ FAIL", "\n")

cat("\n\nTest 2: SR_AMP with postprocess DISABLED\n")
cat("-----------------------------------------\n")

test_params_2 <- test_params_1
test_params_2$enable_postprocess = FALSE

config_2 <- generate_sr_amp_config(test_params_2)

cat("\nGenerated postprocess section:\n")
cat("  enabled:", config_2$postprocess$enabled, "\n")
cat("  Type:", class(config_2$postprocess$enabled), "\n")
cat("  Expected: 0 (numeric integer)\n")
cat("  Result:", if (identical(config_2$postprocess$enabled, 0L)) "✅ PASS" else "❌ FAIL", "\n")

cat("\n\nTest 3: SR_AMP with postprocess NOT SET (default)\n")
cat("--------------------------------------------------\n")

test_params_3 <- test_params_1
test_params_3$enable_postprocess = NULL

config_3 <- generate_sr_amp_config(test_params_3)

cat("\nGenerated postprocess section:\n")
cat("  enabled:", config_3$postprocess$enabled, "\n")
cat("  Type:", class(config_3$postprocess$enabled), "\n")
cat("  Expected: 0 (numeric integer, default when NULL)\n")
cat("  Result:", if (identical(config_3$postprocess$enabled, 0L)) "✅ PASS" else "❌ FAIL", "\n")

cat("\n\nTest 4: SR_META with postprocess ENABLED\n")
cat("-----------------------------------------\n")

test_params_4 <- list(
  run_id = "test_meta_postprocess",
  pipeline = "sr_meta",
  technology = "illumina",
  sample_type = "gut",
  paired_end = TRUE,
  input_r1 = "/path/to/r1.fastq",
  input_r2 = "/path/to/r2.fastq",
  output_dir = file.path(repo_root, "outputs"),
  quality_threshold = 20,
  min_read_length = 50,
  threads = 4,
  kraken_db = "/path/to/kraken2/db",
  enable_postprocess = TRUE,
  output_selected = c("all")
)

config_4 <- generate_sr_meta_config(test_params_4)

cat("\nGenerated postprocess section:\n")
cat("  enabled:", config_4$postprocess$enabled, "\n")
cat("  Type:", class(config_4$postprocess$enabled), "\n")
cat("  Expected: 1 (numeric integer)\n")
cat("  Result:", if (identical(config_4$postprocess$enabled, 1L)) "✅ PASS" else "❌ FAIL", "\n")

cat("\n\nTest 5: SR_META with postprocess DISABLED\n")
cat("------------------------------------------\n")

test_params_5 <- test_params_4
test_params_5$enable_postprocess = FALSE

config_5 <- generate_sr_meta_config(test_params_5)

cat("\nGenerated postprocess section:\n")
cat("  enabled:", config_5$postprocess$enabled, "\n")
cat("  Type:", class(config_5$postprocess$enabled), "\n")
cat("  Expected: 0 (numeric integer)\n")
cat("  Result:", if (identical(config_5$postprocess$enabled, 0L)) "✅ PASS" else "❌ FAIL", "\n")

cat("\n\nTest 6: Verify JSON serialization (auto_unbox behavior)\n")
cat("-------------------------------------------------------\n")

json_output <- jsonlite::toJSON(config_1$postprocess, auto_unbox = TRUE, pretty = TRUE)
cat("\nJSON output:\n")
cat(json_output, "\n")

expected_json <- '{\n  "enabled": 1\n}'
cat("\nExpected:\n")
cat(expected_json, "\n")

cat("\nJSON matches expected format:", if (grepl('"enabled":\\s*1', json_output)) "✅ PASS" else "❌ FAIL", "\n")

cat("\n========== TEST COMPLETE ==========\n")
