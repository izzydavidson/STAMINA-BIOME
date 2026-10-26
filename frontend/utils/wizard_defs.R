# ---------------------------------------------------------------------------
# wizard_defs.R
# Shared definitions for the Shiny setup wizard.
# Mirrors wizard.R and cli/setup.py paths exactly.
# Do NOT modify main/ or cli/.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
wizard_repo_root <- function() normalizePath(dirname(getwd()))

wizard_marker_file <- function(repo_root = wizard_repo_root()) {
  file.path(repo_root, ".setup_complete")
}

wizard_is_complete <- function(repo_root = wizard_repo_root()) {
  file.exists(wizard_marker_file(repo_root))
}

wizard_mark_complete <- function(repo_root = wizard_repo_root()) {
  writeLines(format(Sys.time()), wizard_marker_file(repo_root))
}

wizard_save_bracken_readlen <- function(value, repo_root = wizard_repo_root()) {
  writeLines(as.character(value), file.path(repo_root, ".bracken_readlen"))
}

wizard_load_bracken_readlen <- function(repo_root = wizard_repo_root()) {
  path <- file.path(repo_root, ".bracken_readlen")
  if (!file.exists(path)) return("auto")
  val <- trimws(readLines(path, warn = FALSE)[1])
  if (is.na(val) || !nzchar(val)) return("auto")
  val
}

wizard_check_docker <- function() {
  tryCatch({
    result <- system2("docker", args = "info",
                      stdout = TRUE, stderr = TRUE, timeout = 8)
    sc <- attr(result, "status")
    is.null(sc) || sc == 0L
  }, error = function(e) FALSE)
}

# ---------------------------------------------------------------------------
# Database, tool, and model definitions
# Must match wizard.R / cli/setup.py exactly (URLs, dest paths)
# ---------------------------------------------------------------------------
WIZARD_DATABASES <- list(
  list(
    id          = "kraken2-standard-8",
    name        = "Kraken2 Standard-8",
    desc        = "8 GB: Bacteria, Archaea, Viral, Human",
    size        = "8",
    pipelines   = "sr_meta, lr_meta",
    url         = "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_08gb_20240605.tar.gz",
    is_tarball  = TRUE
  ),
  list(
    id          = "kraken2-standard-16",
    name        = "Kraken2 Standard-16",
    desc        = "16 GB: Bacteria, Archaea, Viral, Human",
    size        = "16",
    pipelines   = "sr_meta, lr_meta",
    url         = "https://genome-idx.s3.amazonaws.com/kraken/k2_standard_16gb_20240605.tar.gz",
    is_tarball  = TRUE
  ),
  list(
    id          = "emu-default",
    name        = "Emu Default",
    desc        = "17K species for long-read amplicon",
    size        = "0.1",
    pipelines   = "lr_amp",
    url         = "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da8a656946a0023a7a54ef",
    is_tarball  = TRUE
  ),
  list(
    id          = "emu-silva",
    name        = "Emu SILVA",
    desc        = "100K+ species for long-read amplicon",
    size        = "0.6",
    pipelines   = "lr_amp",
    url         = "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da837c7d0187023fbc4993",
    is_tarball  = TRUE
  ),
  list(
    id          = "emu-rdp",
    name        = "Emu RDP (RECOMMENDED)",
    desc        = "280K+ species for long-read amplicon",
    size        = "1.3",
    pipelines   = "lr_amp",
    url         = "https://files.osf.io/v1/resources/56uf7/providers/osfstorage/63da84611e96860221b25460",
    is_tarball  = TRUE
  ),
  list(
    id            = "qiime2-silva-138",
    name          = "QIIME2 SILVA 138",
    desc          = "Naive-Bayes classifier — REQUIRED for sr_amp",
    size          = "0.21",
    pipelines     = "sr_amp",
    url           = "https://data.qiime2.org/classifiers/sklearn-1.4.2/silva/silva-138-99-nb-classifier.qza",
    is_single_file = TRUE,
    dest_subdir   = "reference/qiime2",
    dest_filename = "silva-138-99-nb-classifier.qza"
  ),
  list(
    id            = "human-grch38",
    name          = "Human GRCh38",
    desc          = "Reference genome for host-read depletion",
    size          = "0.9",
    pipelines     = "sr_meta, lr_meta",
    url           = "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz",
    is_single_file = TRUE,
    dest_subdir   = "reference/human/grch38",
    dest_filename = "GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz"
  )
)

WIZARD_TOOLS <- list(
  list(
    id      = "valencia",
    name    = "VALENCIA",
    desc    = "Vaginal Community State Type (CST) classification",
    size    = "~2 MB",
    samples = "vaginal",
    url     = "https://github.com/ravel-lab/VALENCIA/archive/refs/heads/master.zip"
  )
)

# minimap2 reference genome indexes — built locally from the GRCh38 FASTA.
# Mirrors cli/setup.py build_minimap2_index() exactly (all 4 strategies):
#   dest: main/data/reference/human/grch38/
# The FASTA (human-grch38 database) must be downloaded first.
# mmi_name:  output filename — matches CLI naming exactly
# mm2_flags: extra flags passed to minimap2 (CLI index_configs entries)
# split:     whether split_prefix=1 is needed at alignment time
WIZARD_REFERENCE_INDEXES <- list(
  list(
    id        = "index-minimap2-grch38-standard",
    name      = "Human GRCh38 Index — Standard",
    desc      = "Fastest alignment. Requires ~6-8 GB RAM to build.",
    size      = "~4 GB",
    mmi_name  = "GRCh38.primary_assembly.genome.mmi",
    mm2_flags = character(0),
    split     = 0L,
    requires  = "Requires: Human GRCh38 FASTA + minimap2 in PATH"
  ),
  list(
    id        = "index-minimap2-grch38-lowmem",
    name      = "Human GRCh38 Index — Low Memory",
    desc      = "Moderate RAM usage. Requires ~4 GB RAM to build (-I 4G).",
    size      = "~4 GB",
    mmi_name  = "GRCh38.primary_assembly.genome.lowmem.mmi",
    mm2_flags = c("-I", "4G"),
    split     = 0L,
    requires  = "Requires: Human GRCh38 FASTA + minimap2 in PATH"
  ),
  list(
    id        = "index-minimap2-grch38-split2g",
    name      = "Human GRCh38 Index — Split 2 GB",
    desc      = "Lowest RAM. Splits index into 2 GB chunks (-I 2G). Uses split-prefix at runtime.",
    size      = "~4 GB",
    mmi_name  = "GRCh38.primary_assembly.genome.split2G.mmi",
    mm2_flags = c("-I", "2G"),
    split     = 1L,
    requires  = "Requires: Human GRCh38 FASTA + minimap2 in PATH"
  ),
  list(
    id        = "index-minimap2-grch38-split4g",
    name      = "Human GRCh38 Index — Split 4 GB",
    desc      = "Low RAM. Splits index into 4 GB chunks (-I 4G). Uses split-prefix at runtime.",
    size      = "~4 GB",
    mmi_name  = "GRCh38.primary_assembly.genome.split4G.mmi",
    mm2_flags = c("-I", "4G"),
    split     = 1L,
    requires  = "Requires: Human GRCh38 FASTA + minimap2 in PATH"
  )
)

# Dorado basecalling binaries — shown as cards in the Tools section.
# Directory naming matches cli/setup.py convention:
#   v1.3.1 -> tools/dorado (Linux) + tools/dorado-host (macOS)
#   other  -> tools/dorado-{ver} (Linux) + tools/dorado-{ver}-host (macOS)
WIZARD_DORADO_BINARIES <- list(
  list(
    id      = "dorado-1.3.1",
    version = "1.3.1",
    name    = "Dorado 1.3.1 (Recommended)",
    desc    = "Latest binary for modern 5 kHz R10.4.1 data. Required for HAC/SUP/FAST v5.2.0 models.",
    size    = "~450 MB"
  ),
  list(
    id      = "dorado-0.9.6",
    version = "0.9.6",
    name    = "Dorado 0.9.6 (Legacy)",
    desc    = "Legacy binary for older 4 kHz R10.4.1 E8.2 data. Required for HAC v3.5.2 model.",
    size    = "~400 MB"
  )
)

WIZARD_DORADO_MODELS <- list(
  list(id = "dna_r10.4.1_e8.2_400bps_hac@v5.2.0",
       name = "HAC v5.2.0 (RECOMMENDED)",
       desc = "High accuracy for modern 5kHz ONT data — requires Dorado 1.3.1",
       size = "~400 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_sup@v5.2.0",
       name = "SUP v5.2.0",
       desc = "Super accuracy for 5kHz ONT data (slower) — requires Dorado 1.3.1",
       size = "~400 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_fast@v5.2.0",
       name = "FAST v5.2.0",
       desc = "Fast mode for 5kHz ONT data — requires Dorado 1.3.1",
       size = "~300 MB"),
  list(id = "dna_r10.4.1_e8.2_400bps_hac@v3.5.2",
       name = "HAC v3.5.2 (Legacy 4kHz)",
       desc = "High accuracy for LEGACY 4kHz R10.4.1 E8.2 data — requires Dorado 0.9.6",
       size = "~400 MB")
)

# ---------------------------------------------------------------------------
# Detection  — paths must match wizard.R exactly
# ---------------------------------------------------------------------------
wizard_detect_installed <- function(repo_root = wizard_repo_root()) {
  inst <- list(databases = character(0), tools = character(0), models = character(0))

  for (db in WIZARD_DATABASES) {
    if (isTRUE(db$is_single_file)) {
      p <- file.path(repo_root, "main", "data", db$dest_subdir, db$dest_filename)
      if (file.exists(p)) inst$databases <- c(inst$databases, db$id)
    } else {
      p <- file.path(repo_root, "main", "data", "databases", db$id)
      if (dir.exists(p) && length(list.files(p)) > 0)
        inst$databases <- c(inst$databases, db$id)
    }
  }

  # VALENCIA — check canonical centroids path (matches wizard.R line 41-44)
  centroids <- file.path(repo_root, "tools", "VALENCIA", "CST_centroids_012920.csv")
  if (file.exists(centroids)) inst$tools <- c(inst$tools, "valencia")

  # minimap2 human genome indexes — check each specific .mmi file by canonical name
  # Matches cli/setup.py naming exactly (all 4 strategies)
  grch38_ref_dir <- file.path(repo_root, "main", "data", "reference", "human", "grch38")
  for (idx in WIZARD_REFERENCE_INDEXES) {
    mmi_path <- file.path(grch38_ref_dir, idx$mmi_name)
    if (file.exists(mmi_path) && file.size(mmi_path) > 1e6)
      inst$tools <- c(inst$tools, idx$id)
  }

  # Dorado binaries — requires BOTH the host binary and the Linux Docker binary.
  # On macOS: host binary (dorado-host/) + Linux binary (dorado/) for Docker.
  # On Linux: only the platform binary is needed.
  sysname <- Sys.info()[["sysname"]]
  for (b in WIZARD_DORADO_BINARIES) {
    ver <- b$version
    linux_dir_name <- if (ver == "1.3.1") "dorado" else paste0("dorado-", ver)
    linux_bin_path <- file.path(repo_root, "tools", linux_dir_name, "bin", "dorado")

    if (sysname == "Darwin") {
      host_dir      <- if (ver == "1.3.1") "dorado-host" else paste0("dorado-", ver, "-host")
      host_bin_path <- file.path(repo_root, "tools", host_dir, "bin", "dorado")
      # Both must exist: macOS binary for native use + Linux binary for Docker
      if (file.exists(host_bin_path) && file.exists(linux_bin_path))
        inst$tools <- c(inst$tools, b$id)
    } else {
      if (file.exists(linux_bin_path)) inst$tools <- c(inst$tools, b$id)
    }
  }

  # Dorado models — download target is tools/models/dorado/<model_id>/
  models_dir <- file.path(repo_root, "tools", "models", "dorado")
  for (m in WIZARD_DORADO_MODELS) {
    if (dir.exists(file.path(models_dir, m$id)))
      inst$models <- c(inst$models, m$id)
  }

  inst
}

# ---------------------------------------------------------------------------
# wizard_run_downloads()
# Designed to be called from a background Rscript subprocess.
# Writes structured lines to stdout — parsed by the Shiny polling observer.
#
# Line protocol:
#   [LOG] text       — regular info line
#   [OK]  text       — success (green)
#   [ERR] text       — error   (red)
#   [PROG:N] text    — progress bar (N = 0–100)
#   [DONE:ok]        — all completed successfully
#   [DONE:fail]      — one or more items failed
# ---------------------------------------------------------------------------
wiz_emit <- function(prefix, msg) {
  cat(prefix, msg, "\n", sep = "")
  flush.console()
}
wiz_log  <- function(msg)        wiz_emit("[LOG] ", msg)
wiz_ok   <- function(msg)        wiz_emit("[OK] ",  msg)
wiz_err  <- function(msg)        wiz_emit("[ERR] ", msg)
wiz_prog <- function(pct, text)  { cat("[PROG:", pct, "] ", text, "\n", sep = ""); flush.console() }

# ---------------------------------------------------------------------------
# find_dorado_bin()
# Find the best available Dorado host binary in tools_dir.
# Prefers 1.3.1 over 0.9.6. Returns list(bin, version) or NULL.
# ---------------------------------------------------------------------------
find_dorado_bin <- function(tools_dir) {
  sysname <- Sys.info()[["sysname"]]
  for (ver in c("1.3.1", "0.9.6")) {
    if (sysname == "Darwin") {
      host_dir <- if (ver == "1.3.1") "dorado-host" else paste0("dorado-", ver, "-host")
      bin <- file.path(tools_dir, host_dir, "bin", "dorado")
    } else {
      dir_name <- if (ver == "1.3.1") "dorado" else paste0("dorado-", ver)
      bin <- file.path(tools_dir, dir_name, "bin", "dorado")
    }
    if (file.exists(bin)) return(list(bin = bin, version = ver))
  }
  NULL
}

# ---------------------------------------------------------------------------
# install_dorado_binary()
# Download and install a Dorado binary for the given version.
# On macOS: downloads both the host binary (for running natively) and the
# Linux binary (for mounting inside Docker containers).
# On Linux: downloads the platform binary only.
# Returns TRUE on success, FALSE on failure.
# ---------------------------------------------------------------------------
install_dorado_binary <- function(dorado_version, tools_dir) {
  sysname <- Sys.info()[["sysname"]]
  machine <- Sys.info()[["machine"]]

  dorado_dir_name      <- if (dorado_version == "1.3.1") "dorado"
                          else paste0("dorado-", dorado_version)
  dorado_host_dir_name <- if (dorado_version == "1.3.1") "dorado-host"
                          else paste0("dorado-", dorado_version, "-host")

  # Increase download timeout for large binaries (CDN can be slow)
  # CLI uses urllib with no timeout; R default is 60s which is too short.
  old_timeout <- getOption("timeout")
  options(timeout = 600)
  on.exit(options(timeout = old_timeout), add = TRUE)

  success <- TRUE

  if (sysname == "Darwin") {
    host_platform <- ifelse(machine == "arm64", "osx-arm64", "osx-x64")

    # 1. macOS host binary — used to run Dorado natively (model downloads etc.)
    dorado_host_dir <- file.path(tools_dir, dorado_host_dir_name)
    dorado_bin      <- file.path(dorado_host_dir, "bin", "dorado")

    if (!file.exists(dorado_bin)) {
      wiz_log(sprintf("Downloading Dorado %s for macOS...", dorado_version))
      dir.create(dorado_host_dir, recursive = TRUE, showWarnings = FALSE)
      dorado_url     <- sprintf(
        "https://cdn.oxfordnanoportal.com/software/analysis/dorado-%s-%s.zip",
        dorado_version, host_platform)
      dorado_archive <- file.path(dorado_host_dir, "dorado.zip")

      ok <- tryCatch({
        # Dorado binaries are hosted only on the ONT CDN (~400 MB–4 GB per file).
        # Allow up to 2 hours; the connect-timeout fails fast if the CDN is unreachable.
        rc_dl <- system(sprintf(
          "curl -fsSL --connect-timeout 30 --max-time 7200 -o '%s' '%s'",
          dorado_archive, dorado_url), wait = TRUE)
        if (rc_dl != 0 || !file.exists(dorado_archive) || file.size(dorado_archive) < 1e6) {
          wiz_err(sprintf("CDN download failed (curl exit %d)", rc_dl))
          if (file.exists(dorado_archive)) unlink(dorado_archive)
          return(FALSE)
        }
        wiz_log("Extracting Dorado macOS binary...")
        unzip(dorado_archive, exdir = dorado_host_dir, overwrite = TRUE)
        unlink(dorado_archive)

        extracted_dirs <- list.dirs(dorado_host_dir, full.names = TRUE, recursive = FALSE)
        if (length(extracted_dirs) == 1 && basename(extracted_dirs[1]) != "bin") {
          for (item in list.files(extracted_dirs[1], full.names = TRUE)) {
            dest_item <- file.path(dorado_host_dir, basename(item))
            if (!file.exists(dest_item)) file.rename(item, dest_item)
          }
          unlink(extracted_dirs[1], recursive = TRUE)
        }

        if (file.exists(dorado_bin)) {
          Sys.chmod(dorado_bin, "0755")
          wiz_ok(sprintf("Dorado %s macOS binary ready", dorado_version))
          TRUE
        } else {
          wiz_err("Dorado macOS binary not found after extraction")
          FALSE
        }
      }, error = function(e) {
        wiz_err(paste("Failed to download Dorado macOS binary:", e$message))
        if (file.exists(dorado_archive)) unlink(dorado_archive)
        FALSE
      })
      if (!ok) success <- FALSE
    } else {
      wiz_log(sprintf("Dorado %s macOS binary already present", dorado_version))
    }

    # 2. Linux binary for Docker containers (macOS cannot run Linux binaries natively).
    # run_in_container.sh defaults to linux/arm64 on ARM Macs and linux/amd64 on x64.
    # The Linux binary architecture MUST match the container platform; a mismatch
    # causes QEMU to fail with "Could not open /lib64/ld-linux-x86-64.so.2".
    linux_platform_str <- ifelse(machine %in% c("arm64", "aarch64"), "linux-arm64", "linux-x64")
    dorado_linux_dir <- file.path(tools_dir, dorado_dir_name)
    dorado_linux_bin <- file.path(dorado_linux_dir, "bin", "dorado")

    # Check if an existing binary has the correct architecture for the container.
    needs_linux_download <- !file.exists(dorado_linux_bin)
    if (!needs_linux_download) {
      file_info <- tryCatch(
        system(sprintf("file '%s' 2>/dev/null", dorado_linux_bin), intern = TRUE),
        error = function(e) "")
      expected_arch <- if (machine %in% c("arm64", "aarch64")) "aarch64" else "x86-64"
      if (length(file_info) == 0 || !grepl(expected_arch, file_info[1], fixed = TRUE)) {
        wiz_log(sprintf(
          "Existing Docker binary is wrong architecture (expected %s) — replacing with %s...",
          expected_arch, linux_platform_str))
        unlink(dorado_linux_dir, recursive = TRUE)
        dir.create(dorado_linux_dir, recursive = TRUE, showWarnings = FALSE)
        needs_linux_download <- TRUE
      }
    }

    if (needs_linux_download) {
      wiz_log(sprintf("Downloading Dorado %s Linux binary (%s) for Docker...",
                      dorado_version, linux_platform_str))
      dir.create(dorado_linux_dir, recursive = TRUE, showWarnings = FALSE)
      dorado_linux_url     <- sprintf(
        "https://cdn.oxfordnanoportal.com/software/analysis/dorado-%s-%s.tar.gz",
        dorado_version, linux_platform_str)
      dorado_linux_archive <- file.path(dorado_linux_dir, "dorado.tar.gz")

      ok_linux <- tryCatch({
        # Dorado binaries are hosted only on the ONT CDN (~400 MB–4 GB per file).
        # Allow up to 2 hours; the connect-timeout fails fast if the CDN is unreachable.
        rc_dl <- system(sprintf(
          "curl -fsSL --connect-timeout 30 --max-time 7200 -o '%s' '%s'",
          dorado_linux_archive, dorado_linux_url), wait = TRUE)

        # Verify the download completed before extracting
        if (rc_dl != 0 || !file.exists(dorado_linux_archive) ||
            file.size(dorado_linux_archive) < 1e6) {
          wiz_err(sprintf("CDN download failed (curl exit %d)", rc_dl))
          if (file.exists(dorado_linux_archive)) unlink(dorado_linux_archive)
          return(FALSE)
        }

        wiz_log("Extracting Dorado Linux binary...")
        system(sprintf("cd '%s' && tar xzf dorado.tar.gz", dorado_linux_dir))
        unlink(dorado_linux_archive)

        extracted_dirs <- list.dirs(dorado_linux_dir, full.names = TRUE, recursive = FALSE)
        if (length(extracted_dirs) == 1 && basename(extracted_dirs[1]) != "bin") {
          for (item in list.files(extracted_dirs[1], full.names = TRUE)) {
            dest_item <- file.path(dorado_linux_dir, basename(item))
            if (!file.exists(dest_item)) file.rename(item, dest_item)
          }
          unlink(extracted_dirs[1], recursive = TRUE)
        }

        if (file.exists(dorado_linux_bin)) {
          Sys.chmod(dorado_linux_bin, "0755")
          wiz_ok(sprintf("Dorado %s Linux binary (%s) ready for Docker",
                         dorado_version, linux_platform_str))
          TRUE
        } else {
          wiz_err("Dorado Linux binary not found after extraction")
          FALSE
        }
      }, error = function(e) {
        wiz_err(paste("Failed to download Dorado Linux binary:", e$message))
        if (file.exists(dorado_linux_archive)) unlink(dorado_linux_archive)
        FALSE
      })
      if (!ok_linux) success <- FALSE
    } else {
      wiz_log(sprintf("Dorado %s Linux binary (%s) already present for Docker",
                      dorado_version, linux_platform_str))
    }

  } else if (sysname == "Linux") {
    platform_str <- ifelse(machine %in% c("x86_64", "amd64"), "linux-x64", "linux-arm64")
    dorado_dir   <- file.path(tools_dir, dorado_dir_name)
    dorado_bin   <- file.path(dorado_dir, "bin", "dorado")

    if (!file.exists(dorado_bin)) {
      wiz_log(sprintf("Downloading Dorado %s for Linux...", dorado_version))
      dir.create(dorado_dir, recursive = TRUE, showWarnings = FALSE)
      dorado_url     <- sprintf(
        "https://cdn.oxfordnanoportal.com/software/analysis/dorado-%s-%s.tar.gz",
        dorado_version, platform_str)
      dorado_archive <- file.path(dorado_dir, "dorado.tar.gz")

      ok <- tryCatch({
        download.file(dorado_url, dorado_archive, mode = "wb", quiet = TRUE)
        wiz_log("Extracting Dorado...")
        system(sprintf("cd '%s' && tar xzf dorado.tar.gz", dorado_dir))
        unlink(dorado_archive)

        extracted_dirs <- list.dirs(dorado_dir, full.names = TRUE, recursive = FALSE)
        if (length(extracted_dirs) == 1 && basename(extracted_dirs[1]) != "bin") {
          for (item in list.files(extracted_dirs[1], full.names = TRUE)) {
            dest_item <- file.path(dorado_dir, basename(item))
            if (!file.exists(dest_item)) file.rename(item, dest_item)
          }
          unlink(extracted_dirs[1], recursive = TRUE)
        }

        if (file.exists(dorado_bin)) {
          Sys.chmod(dorado_bin, "0755")
          wiz_ok(sprintf("Dorado %s binary ready", dorado_version))
          TRUE
        } else {
          wiz_err("Dorado binary not found after extraction")
          FALSE
        }
      }, error = function(e) {
        wiz_err(paste("Failed to download Dorado:", e$message))
        if (file.exists(dorado_archive)) unlink(dorado_archive)
        FALSE
      })
      if (!ok) success <- FALSE
    } else {
      wiz_log(sprintf("Dorado %s already present", dorado_version))
    }

  } else {
    wiz_err(paste("Unsupported OS for Dorado:", sysname))
    success <- FALSE
  }

  success
}

# ---------------------------------------------------------------------------
# download_legacy_model_v352()
# Download the legacy v3.5.2 model using Dorado 0.9.6.
# Dorado 1.3.1+ no longer includes v3.5.2 in its model registry,
# so we need to use an older version (0.9.6) to download it.
# ---------------------------------------------------------------------------
download_legacy_model_v352 <- function(models_dir) {
  sysname <- Sys.info()[["sysname"]]
  machine <- Sys.info()[["machine"]]

  # Determine platform for Dorado 0.9.6
  if (sysname == "Darwin") {
    platform_str <- if (machine == "arm64") "osx-arm64" else "osx-x64"
    archive_ext <- "zip"
  } else if (sysname == "Linux") {
    platform_str <- if (machine %in% c("x86_64", "amd64")) "linux-x64" else "linux-arm64"
    archive_ext <- "tar.gz"
  } else {
    wiz_err("Unsupported platform for legacy model download")
    return(1)
  }

  version <- "0.9.6"
  filename <- sprintf("dorado-%s-%s.%s", version, platform_str, archive_ext)
  url <- sprintf("https://cdn.oxfordnanoportal.com/software/analysis/%s", filename)

  # Create temporary directory
  temp_dir <- tempdir()
  archive_path <- file.path(temp_dir, filename)
  extract_dir <- file.path(temp_dir, sprintf("dorado-%s-%s", version, platform_str))

  tryCatch({
    # Download Dorado 0.9.6
    wiz_log(sprintf("Downloading Dorado %s (temporary, for legacy model download)...", version))
    download.file(url, archive_path, mode = "wb", quiet = TRUE)

    # Extract
    wiz_log("Extracting Dorado 0.9.6...")
    if (archive_ext == "zip") {
      unzip(archive_path, exdir = temp_dir, overwrite = TRUE)
    } else {
      system(sprintf("cd '%s' && tar xzf '%s'", temp_dir, filename), wait = TRUE)
    }

    # Find the dorado binary
    dorado_bin <- file.path(extract_dir, "bin", "dorado")
    if (!file.exists(dorado_bin)) {
      wiz_err("Dorado binary not found in archive")
      return(1)
    }

    # Make executable
    Sys.chmod(dorado_bin, "0755")

    # Download the v3.5.2 model using Dorado 0.9.6
    wiz_log("Downloading v3.5.2 model using Dorado 0.9.6...")
    cmd <- sprintf("'%s' download --model dna_r10.4.1_e8.2_400bps_hac@v3.5.2 --models-directory '%s' 2>&1",
                   dorado_bin, models_dir)

    # On macOS, set DYLD_LIBRARY_PATH to point to the lib directory
    if (sysname == "Darwin") {
      lib_dir <- file.path(extract_dir, "lib")
      old_dyld <- Sys.getenv("DYLD_LIBRARY_PATH", unset = NA)
      Sys.setenv(DYLD_LIBRARY_PATH = lib_dir)
      rc <- system(cmd, wait = TRUE)
      if (!is.na(old_dyld)) {
        Sys.setenv(DYLD_LIBRARY_PATH = old_dyld)
      } else {
        Sys.unsetenv("DYLD_LIBRARY_PATH")
      }
    } else {
      rc <- system(cmd, wait = TRUE)
    }

    # Clean up temporary files
    unlink(archive_path)
    unlink(extract_dir, recursive = TRUE)

    # Check if model was downloaded
    model_path <- file.path(models_dir, "dna_r10.4.1_e8.2_400bps_hac@v3.5.2")
    if (rc == 0 && dir.exists(model_path)) {
      wiz_log("Legacy model downloaded successfully")
      return(0)
    } else {
      wiz_err("Model download failed")
      return(1)
    }

  }, error = function(e) {
    wiz_err(paste("Error downloading legacy model:", e$message))
    unlink(archive_path, force = TRUE)
    unlink(extract_dir, recursive = TRUE, force = TRUE)
    return(1)
  })
}

# ---------------------------------------------------------------------------
# build_minimap2_index_wiz()
# Build a minimap2 index from the GRCh38 FASTA.
# Mirrors cli/setup.py build_minimap2_index() exactly for all 4 strategies:
#   minimap2 -x map-ont [mm2_flags] -d <output.mmi> <fasta>
#
# idx: one entry from WIZARD_REFERENCE_INDEXES (has mmi_name, mm2_flags)
# Requires minimap2 to be in PATH on the host machine.
# The FASTA must have been downloaded first (human-grch38 database entry).
# ---------------------------------------------------------------------------
build_minimap2_index_wiz <- function(repo_root, idx) {
  grch38_dir <- file.path(repo_root, "main", "data", "reference", "human", "grch38")
  fasta_gz   <- file.path(grch38_dir, "GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz")
  fasta      <- file.path(grch38_dir, "GCA_000001405.15_GRCh38_no_alt_analysis_set.fna")
  mmi_out    <- file.path(grch38_dir, idx$mmi_name)

  # Check minimap2 is available in PATH (same check as cli/setup.py shutil.which)
  mm2_bin <- Sys.which("minimap2")
  if (mm2_bin == "") {
    wiz_err("minimap2 not found in PATH.")
    wiz_err("Install minimap2 (e.g. 'brew install minimap2' or via conda) then retry.")
    wiz_err("Alternatively, use the CLI wizard: python -m cli setup")
    return(FALSE)
  }
  wiz_log(paste("minimap2 found at:", mm2_bin))

  # Check FASTA exists
  if (!file.exists(fasta) && !file.exists(fasta_gz)) {
    wiz_err("GRCh38 FASTA not found. Download the 'Human GRCh38' database first.")
    return(FALSE)
  }

  # Decompress FASTA if needed — matching cli/setup.py decompression step
  if (!file.exists(fasta)) {
    wiz_log("Decompressing GRCh38 FASTA (this may take a few minutes)...")
    rc <- system(sprintf("gunzip -k '%s'", fasta_gz), wait = TRUE)
    if (rc != 0 || !file.exists(fasta)) {
      wiz_err("Failed to decompress FASTA. Check disk space and try again.")
      return(FALSE)
    }
    wiz_ok(paste("FASTA decompressed:", basename(fasta)))
  } else {
    wiz_log(paste("FASTA already decompressed:", basename(fasta)))
  }

  # Check if this specific index already exists
  if (file.exists(mmi_out) && file.size(mmi_out) > 1e6) {
    wiz_ok(paste("Index already exists:", basename(mmi_out)))
    return(TRUE)
  }

  # Build extra flags string — matches CLI index_configs mm2_flags exactly
  extra_flags <- if (length(idx$mm2_flags) > 0) paste(idx$mm2_flags, collapse = " ") else ""
  wiz_log(sprintf("Building minimap2 index: %s", idx$name))
  wiz_log(sprintf("Command: minimap2 -x map-ont %s -d <output> <fasta>", extra_flags))
  wiz_log("This may take 15-30 minutes depending on available RAM.")
  wiz_log(paste("Output:", mmi_out))

  cmd <- sprintf("minimap2 -x map-ont %s -d '%s' '%s' 2>&1",
                 extra_flags, mmi_out, fasta)
  rc  <- system(cmd, wait = TRUE)

  if (rc == 0 && file.exists(mmi_out) && file.size(mmi_out) > 1e6) {
    mmi_mb <- round(file.size(mmi_out) / 1024 / 1024, 0)
    wiz_ok(sprintf("Index built: %s (%d MB)", basename(mmi_out), mmi_mb))
    return(TRUE)
  } else {
    wiz_err(sprintf("minimap2 indexing failed (exit code %d)", rc))
    if (file.exists(mmi_out)) unlink(mmi_out)  # Remove partial file
    return(FALSE)
  }
}

wizard_run_downloads <- function(selected_db_ids, selected_tool_ids,
                                 selected_model_ids, repo_root) {

  data_dir   <- file.path(repo_root, "main", "data", "databases")
  tools_dir  <- file.path(repo_root, "tools")
  models_dir <- file.path(tools_dir, "models", "dorado")
  dir.create(data_dir,   recursive = TRUE, showWarnings = FALSE)
  dir.create(models_dir, recursive = TRUE, showWarnings = FALSE)

  total  <- length(selected_db_ids) + length(selected_tool_ids) + length(selected_model_ids)
  done   <- 0L
  failed <- character(0)

  wiz_log(paste("Repository:", repo_root))
  wiz_log(paste("Total items to install:", total))
  wiz_prog(0, "Starting installation...")

  # ---- Databases ----
  if (length(selected_db_ids) > 0) {
    wiz_log(">>> Installing databases")
    for (db_id in selected_db_ids) {
      db <- Filter(function(x) x$id == db_id, WIZARD_DATABASES)[[1]]
      done  <- done + 1L
      wiz_prog(round(done / (total + 1) * 95), paste("Installing", db$name))
      wiz_log(paste("Installing:", db$name, sprintf("(~%s GB)", db$size)))

      t0 <- proc.time()["elapsed"]

      tryCatch({
        if (isTRUE(db$is_single_file)) {
          dest_dir  <- file.path(repo_root, "main", "data", db$dest_subdir)
          dest_file <- file.path(dest_dir, db$dest_filename)
          dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)

          if (file.exists(dest_file) && file.size(dest_file) > 1e6) {
            wiz_ok(paste(db$name, "already installed"))
          } else {
            wiz_log(paste("Downloading:", db$url))
            download.file(db$url, dest_file, mode = "wb", quiet = TRUE, method = "auto")
            elapsed <- round(proc.time()["elapsed"] - t0, 1)
            if (file.exists(dest_file) && file.size(dest_file) > 1e6) {
              wiz_ok(sprintf("%s completed (%.1f MB, %.1fs)",
                             db$name, file.size(dest_file) / 1024 / 1024, elapsed))
            } else {
              wiz_err(paste(db$name, "failed: file too small or missing"))
              failed <- c(failed, db$name)
              if (file.exists(dest_file)) unlink(dest_file)
            }
          }
        } else {
          db_path      <- file.path(data_dir, db$id)
          archive_path <- file.path(data_dir, paste0(db$id, ".tar.gz"))

          if (dir.exists(db_path) && length(list.files(db_path)) > 0) {
            wiz_ok(paste(db$name, "already installed"))
          } else {
            wiz_log(paste("Downloading:", db$url))
            download.file(db$url, archive_path, mode = "wb", quiet = TRUE, method = "auto")

            if (!file.exists(archive_path) || file.size(archive_path) < 1e6) {
              wiz_err(paste(db$name, "failed: download too small"))
              failed <- c(failed, db$name)
              if (file.exists(archive_path)) unlink(archive_path)
            } else {
              arch_mb <- round(file.size(archive_path) / 1024 / 1024, 1)
              wiz_log(paste("Downloaded:", arch_mb, "MB — extracting..."))
              dir.create(db_path, recursive = TRUE, showWarnings = FALSE)
              rc <- untar(archive_path, exdir = db_path)
              elapsed <- round(proc.time()["elapsed"] - t0, 1)
              if (rc == 0 && dir.exists(db_path) && length(list.files(db_path)) > 0) {
                unlink(archive_path)
                wiz_ok(sprintf("%s completed (%.1fs)", db$name, elapsed))
              } else {
                wiz_err(paste(db$name, "failed: extraction error"))
                failed <- c(failed, db$name)
                unlink(archive_path, force = TRUE)
                unlink(db_path, recursive = TRUE, force = TRUE)
              }
            }
          }
        }
      }, error = function(e) {
        wiz_err(paste(db$name, "error:", e$message))
        failed <<- c(failed, db$name)
      })
    }
  }

  # ---- Tools (VALENCIA + Dorado binaries) ----
  if (length(selected_tool_ids) > 0) {
    wiz_log(">>> Installing tools")
    for (tool_id in selected_tool_ids) {
      done <- done + 1L

      if (startsWith(tool_id, "dorado-")) {
        # Dorado binary download — strip "dorado-" prefix to get version
        ver <- sub("^dorado-", "", tool_id)
        wiz_prog(round(done / (total + 1) * 95), sprintf("Installing Dorado %s", ver))
        wiz_log(sprintf("Installing Dorado %s binary...", ver))
        t0 <- proc.time()["elapsed"]
        ok <- install_dorado_binary(ver, tools_dir)
        elapsed <- round(proc.time()["elapsed"] - t0, 1)
        if (!ok) {
          wiz_err(sprintf("Dorado %s installation failed (%.1fs)", ver, elapsed))
          failed <- c(failed, paste0("Dorado ", ver))
        } else {
          wiz_ok(sprintf("Dorado %s installed (%.1fs)", ver, elapsed))
        }

      } else if (startsWith(tool_id, "index-")) {
        # Reference genome index build — all entries from WIZARD_REFERENCE_INDEXES
        idx_matches <- Filter(function(x) x$id == tool_id, WIZARD_REFERENCE_INDEXES)
        if (length(idx_matches) == 0) {
          wiz_err(paste("Unknown index ID:", tool_id))
          failed <- c(failed, tool_id)
          next
        }
        idx <- idx_matches[[1]]
        wiz_prog(round(done / (total + 1) * 95), paste("Building", idx$name))
        wiz_log(paste("Building:", idx$name))
        wiz_log(paste(idx$requires))

        t0  <- proc.time()["elapsed"]
        ok  <- build_minimap2_index_wiz(repo_root, idx)
        elapsed <- round(proc.time()["elapsed"] - t0, 1)
        if (!ok) {
          wiz_err(sprintf("%s failed (%.1fs)", idx$name, elapsed))
          failed <- c(failed, idx$name)
        } else {
          wiz_ok(sprintf("%s complete (%.1fs)", idx$name, elapsed))
        }

      } else {
        # VALENCIA (and other future analysis tools)
        tool_matches <- Filter(function(x) x$id == tool_id, WIZARD_TOOLS)
        if (length(tool_matches) == 0) {
          wiz_err(paste("Unknown tool ID:", tool_id))
          failed <- c(failed, tool_id)
          next
        }
        tool <- tool_matches[[1]]
        wiz_prog(round(done / (total + 1) * 95), paste("Installing", tool$name))
        wiz_log(paste("Installing:", tool$name))

        tool_dest    <- file.path(tools_dir, toupper(tool$id))
        archive_path <- file.path(tools_dir, paste0(tool$id, ".zip"))
        dir.create(tools_dir, recursive = TRUE, showWarnings = FALSE)

        tryCatch({
          if (dir.exists(tool_dest) && length(list.files(tool_dest)) > 0) {
            centroids <- file.path(tool_dest, "CST_centroids_012920.csv")
            if (file.exists(centroids)) {
              wiz_ok(paste(tool$name, "already installed"))
              next
            }
          }

          t0 <- proc.time()["elapsed"]
          wiz_log(paste("Downloading:", tool$url))
          download.file(tool$url, archive_path, mode = "wb", quiet = TRUE, method = "auto")

          if (!file.exists(archive_path) || file.size(archive_path) < 1e5) {
            wiz_err(paste(tool$name, "failed: download too small"))
            failed <- c(failed, tool$name)
            if (file.exists(archive_path)) unlink(archive_path)
          } else {
            wiz_log("Extracting archive...")
            temp_extract <- file.path(tools_dir, paste0(tool$id, "_temp"))
            unzip(archive_path, exdir = temp_extract, overwrite = TRUE)

            top_dirs <- list.dirs(temp_extract, full.names = TRUE, recursive = FALSE)
            if (length(top_dirs) == 1) {
              if (dir.exists(tool_dest)) unlink(tool_dest, recursive = TRUE)
              file.rename(top_dirs[1], tool_dest)
              unlink(temp_extract, recursive = TRUE)
            } else {
              if (dir.exists(tool_dest)) unlink(tool_dest, recursive = TRUE)
              file.rename(temp_extract, tool_dest)
            }

            unlink(archive_path)
            elapsed <- round(proc.time()["elapsed"] - t0, 1)

            centroids <- file.path(tool_dest, "CST_centroids_012920.csv")
            if (file.exists(centroids)) {
              wiz_ok(sprintf("%s installed (%.1fs)", tool$name, elapsed))
            } else {
              wiz_err(paste(tool$name, "installed but centroids file not found"))
              failed <- c(failed, tool$name)
            }
          }
        }, error = function(e) {
          wiz_err(paste(tool$name, "error:", e$message))
          failed <<- c(failed, tool$name)
          if (file.exists(archive_path)) unlink(archive_path)
        })
      }
    }
  }

  # ---- Dorado Models ----
  if (length(selected_model_ids) > 0) {
    wiz_log(">>> Installing Dorado models")

    # Auto-detect which Dorado binary is available (prefer 1.3.1 over 0.9.6)
    dorado_info    <- find_dorado_bin(tools_dir)
    dorado_bin     <- if (!is.null(dorado_info)) dorado_info$bin     else NULL
    dorado_version <- if (!is.null(dorado_info)) dorado_info$version else NULL

    if (!is.null(dorado_bin) && file.exists(dorado_bin)) {
      wiz_log(sprintf("Using Dorado %s at: %s", dorado_version, dorado_bin))

      for (model_id in selected_model_ids) {
        model <- Filter(function(x) x$id == model_id, WIZARD_DORADO_MODELS)[[1]]
        done  <- done + 1L
        wiz_prog(round(done / (total + 1) * 95), paste("Installing", model$name))
        wiz_log(paste("Installing model:", model$id))

        model_path <- file.path(models_dir, model$id)
        if (dir.exists(model_path) && length(list.files(model_path, recursive = TRUE)) > 5) {
          wiz_ok(paste(model$name, "already installed"))
          next
        }

        t0 <- proc.time()["elapsed"]

        # Special handling for the legacy v3.5.2 model (requires Dorado 0.9.6)
        if (model$id == "dna_r10.4.1_e8.2_400bps_hac@v3.5.2") {
          if (dorado_version == "0.9.6") {
            # User has 0.9.6 — use it directly
            wiz_log("Using Dorado 0.9.6 to download v3.5.2 model...")
            cmd <- sprintf("'%s' download --model %s --models-directory '%s' 2>&1",
                           dorado_bin, model$id, models_dir)
            rc <- system(cmd, wait = TRUE)
          } else {
            # Only 1.3.1 available — temporarily download 0.9.6 for this model
            wiz_log("Note: Legacy v3.5.2 model requires Dorado 0.9.6 for download...")
            rc <- download_legacy_model_v352(models_dir)
          }
        } else {
          # Regular model — use the detected Dorado binary
          cmd <- sprintf("'%s' download --model %s --models-directory '%s' 2>&1",
                         dorado_bin, model$id, models_dir)
          rc  <- system(cmd, wait = TRUE)
        }

        elapsed <- round(proc.time()["elapsed"] - t0, 1)

        if (rc == 0 && dir.exists(model_path) && length(list.files(model_path, recursive = TRUE)) > 5) {
          wiz_ok(sprintf("%s installed (%.1fs)", model$name, elapsed))
        } else {
          wiz_err(sprintf("%s failed (exit %d, %.1fs)", model$name, rc, elapsed))
          failed <- c(failed, model$name)
        }
      }
    } else {
      wiz_err("No Dorado binary found — install a Dorado binary from the Tools section first, then download models")
      for (model_id in selected_model_ids)
        failed <- c(failed, model_id)
    }
  }

  wiz_prog(100, "Installation complete")
  wiz_log("=== Summary ===")
  wiz_log(paste("Succeeded:", total - length(failed), "/", total))

  if (length(failed) > 0) {
    for (f in failed) wiz_err(paste("FAILED:", f))
    cat("[DONE:fail]\n"); flush.console(); flush(stdout())
    quit(save = "no", status = 1L, runLast = FALSE)
  } else {
    wiz_ok("All items installed successfully")
    cat("[DONE:ok]\n"); flush.console(); flush(stdout())
    quit(save = "no", status = 0L, runLast = FALSE)
  }
}
