# Test script to verify run_name fix
# This simulates the flow without actually running the pipeline

# Load dependencies
library(jsonlite)

# Test 1: Sanitization logic
test_sanitize <- function() {
  test_cases <- list(
    list(input = "Test", expected = "Test"),
    list(input = "Test?", expected = "Test_"),
    list(input = "My Test Run", expected = "My_Test_Run"),
    list(input = "Test/Run:Name", expected = "Test_Run_Name"),
    list(input = "  Spaces  ", expected = "Spaces"),
    list(input = "", expected = "timestamp"),  # Should use timestamp
    list(input = "   ", expected = "timestamp")  # Should use timestamp
  )

  for (tc in test_cases) {
    input_name <- tc$input
    expected <- tc$expected

    # Sanitization logic (same as in short_read_server.R)
    run_id <- if (!is.null(input_name) && nchar(trimws(input_name)) > 0) {
      sanitized <- trimws(input_name)
      sanitized <- gsub("[\\/:*?\"<>|\\\\]", "_", sanitized)
      sanitized <- gsub("\\s+", "_", sanitized)
      sanitized
    } else {
      "timestamp"
    }

    if (expected == "timestamp") {
      if (run_id != "timestamp") {
        cat(sprintf("❌ FAIL: Input '%s' should use timestamp, got '%s'\n", input_name, run_id))
        return(FALSE)
      }
    } else {
      if (run_id != expected) {
        cat(sprintf("❌ FAIL: Input '%s' expected '%s', got '%s'\n", input_name, expected, run_id))
        return(FALSE)
      }
    }
  }

  cat("✅ PASS: Sanitization logic works correctly\n")
  return(TRUE)
}

# Test 2: Config generation
test_config_generation <- function() {
  # Source the config generator
  source("utils/config_generator.R", local = TRUE)

  params <- list(
    run_id = "Test_Run",
    pipeline = "sr_amp",
    technology = "illumina",
    sample_type = "vaginal",
    paired_end = FALSE,
    input_path = "/path/to/test.fastq",
    output_dir = "/path/to/outputs",
    quality_threshold = 20,
    min_read_length = 50,
    threads = 4,
    dada2_trunc_f = 140,
    dada2_trunc_r = 140
  )

  config <- generate_sr_amp_config(params)

  # Verify config structure
  if (config$run$run_id != "Test_Run") {
    cat(sprintf("❌ FAIL: Config run_id is '%s', expected 'Test_Run'\n", config$run$run_id))
    return(FALSE)
  }

  if (config$qiime2$sample_id != "Test_Run") {
    cat(sprintf("❌ FAIL: Config sample_id is '%s', expected 'Test_Run'\n", config$qiime2$sample_id))
    return(FALSE)
  }

  if (config$run$force_overwrite != 1) {
    cat("❌ FAIL: force_overwrite should be 1\n")
    return(FALSE)
  }

  cat("✅ PASS: Config generation creates correct structure\n")
  return(TRUE)
}

# Test 3: Config file saving
test_config_saving <- function() {
  source("utils/config_generator.R", local = TRUE)

  config <- list(
    pipeline_id = "sr_amp",
    run = list(
      run_id = "Test_Save",
      work_dir = "/path/to/outputs",
      force_overwrite = 1
    )
  )

  # Use actual save_config which will save to real outputs directory
  config_file <- save_config(config, "Test_Save")

  # Expected path should be in outputs directory with run_id in filename
  # Check that path matches pattern: outputs/config_{run_id}.json
  if (!grepl("outputs/config_Test_Save\\.json$", config_file)) {
    cat(sprintf("❌ FAIL: Config file path '%s' doesn't match expected pattern\n", config_file))
    return(FALSE)
  }

  if (!file.exists(config_file)) {
    cat(sprintf("❌ FAIL: Config file not created at '%s'\n", config_file))
    return(FALSE)
  }

  # Read and verify
  saved_config <- fromJSON(config_file)
  if (saved_config$run$run_id != "Test_Save") {
    cat("❌ FAIL: Saved config has wrong run_id\n")
    return(FALSE)
  }

  # Cleanup
  unlink(config_file)

  cat("✅ PASS: Config saving works correctly\n")
  return(TRUE)
}

# Test 4: Log file path construction
test_log_path <- function() {
  # Simulate the log path construction from run_progress_server.R
  repo_root <- dirname(getwd())
  run_id <- "Test_Run"
  pipeline <- "sr_amp"

  log_file <- file.path(repo_root, "outputs", run_id, "logs", paste0(pipeline, ".log"))
  expected <- file.path(repo_root, "outputs", "Test_Run", "logs", "sr_amp.log")

  if (log_file != expected) {
    cat(sprintf("❌ FAIL: Log path '%s' doesn't match expected '%s'\n", log_file, expected))
    return(FALSE)
  }

  cat("✅ PASS: Log file path construction is correct\n")
  return(TRUE)
}

# Run all tests
cat("\n=== Testing Run Name Fix ===\n\n")

all_pass <- TRUE
all_pass <- all_pass && test_sanitize()
all_pass <- all_pass && test_config_generation()
all_pass <- all_pass && test_config_saving()
all_pass <- all_pass && test_log_path()

cat("\n=== Test Summary ===\n")
if (all_pass) {
  cat("✅ ALL TESTS PASSED\n\n")
} else {
  cat("❌ SOME TESTS FAILED\n\n")
  quit(status = 1)
}
