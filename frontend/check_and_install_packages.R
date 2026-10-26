# Auto-check and install required R packages
# Prints the STAMINA-BIOME startup banner and ensures the environment is ready.

.stamina_biome_banner <- function() {
  X  <- "\033[0m"    # reset
  B  <- "\033[1m"    # bold
  C  <- "\033[96m"   # bright cyan  (box chrome)
  W  <- "\033[97m"   # bright white (subtitle)
  DG <- "\033[90m"   # dark grey    (version)
  Y  <- "\033[93m"   # amber        (status)

  # Pink → purple → blue gradient across the 6 art lines
  ART <- c(
    "\033[38;5;213m",  # hot pink
    "\033[38;5;207m",  # pink-magenta
    "\033[38;5;171m",  # orchid
    "\033[38;5;135m",  # medium purple
    "\033[38;5;99m",   # slate blue
    "\033[38;5;75m"    # cornflower blue
  )

  # ASCII art for "STAMINA-BIOME" — each element is one row, same visual width
  art <- c(
    " ____ _____  _    __  __ ___ _   _    _         ____ ___ ___  __  __ _____ ",
    "/ ___|_   _|/ \\  |  \\/  |_ _| \\ | |  / \\       | __ )_ _/ _ \\|  \\/  | ____|",
    "\\___ \\ | | / _ \\ | |\\/| || ||  \\| | / _ \\ _____|  _ \\| | | | | |\\/| |  _|  ",
    " ___) || |/ ___ \\| |  | || || |\\  |/ ___ \\_____| |_) | | |_| | |  | | |___ ",
    "|____/ |_/_/   \\_\\_|  |_|___|_| \\_/_/   \\_\\    |____/___\\___/|_|  |_|_____|"
  )

  w <- 80L
  top   <- paste0(C, "\u2554", strrep("\u2550", w), "\u2557", X)
  mid   <- paste0(C, "\u2560", strrep("\u2550", w), "\u2563", X)
  bot   <- paste0(C, "\u255a", strrep("\u2550", w), "\u255d", X)
  blank <- paste0(C, "\u2551", strrep(" ", w), "\u2551", X)

  row <- function(plain, display = plain) {
    pad <- max(0L, w - 2L - nchar(plain, type = "chars"))
    paste0(C, "\u2551 ", X, display, strrep(" ", pad), C, " \u2551", X)
  }

  git_ver <- tryCatch({
    v <- system2("git", c("describe", "--tags", "--always"),
                 stdout = TRUE, stderr = FALSE)
    if (length(v) > 0 && nchar(trimws(v[1])) > 0) trimws(v[1]) else "dev"
  }, error = function(e) "dev")

  subp  <- " Standardised, Technology-Agnostic Framework"
  subd  <- paste0(" ", W, "Standardised, Technology-Agnostic Framework", X)
  subp2 <- " for Microbiome Investigation and Analysis"
  subd2 <- paste0(" ", W, "for Microbiome Investigation and Analysis", X)
  vp   <- paste0(" ", git_ver)
  vd   <- paste0(" ", DG, git_ver, X)
  chkp <- " Checking environment\u2026"
  chkd <- paste0(" ", Y, "Checking environment\u2026", X)

  cat("\n")
  cat(top, "\n", sep = "")
  cat(blank, "\n", sep = "")
  for (i in seq_along(art))
    cat(row(art[i], paste0(B, ART[[i]], art[i], X)), "\n", sep = "")
  cat(blank, "\n", sep = "")
  cat(mid, "\n", sep = "")
  cat(row(subp, subd), "\n", sep = "")
  cat(row(subp2, subd2), "\n", sep = "")
  cat(row(vp,   vd),   "\n", sep = "")
  cat(blank, "\n", sep = "")
  cat(mid, "\n", sep = "")
  cat(row(chkp, chkd), "\n", sep = "")
  cat(bot, "\n\n", sep = "")
}

check_and_install_packages <- function(quiet = FALSE) {
  required_packages <- c(
    "shiny", "bslib", "jsonlite", "shinyjs", "shinydashboard",
    "sys", "shinyFiles", "fs", "processx"
  )

  missing_packages <- required_packages[
    !sapply(required_packages, requireNamespace, quietly = TRUE)
  ]

  .log <- function(...) cat("\033[92m[STAMINA-BIOME]\033[0m ", ..., "\n", sep = "")

  if (length(missing_packages) > 0) {
    .log("\033[93mInstalling missing packages: \033[0m",
         paste(missing_packages, collapse = ", "), " \033[90m...\033[0m")
    tryCatch(
      install.packages(missing_packages,
                       repos = "https://cloud.r-project.org/",
                       quiet = quiet),
      error = function(e) {
        stop("[STAMINA-BIOME] install.packages() failed: ", conditionMessage(e))
      }
    )
    still_missing <- missing_packages[
      !sapply(missing_packages, requireNamespace, quietly = TRUE)
    ]
    if (length(still_missing) > 0) {
      stop("[STAMINA-BIOME] Failed to install: ",
           paste(still_missing, collapse = ", "))
    }
    .log("\033[92mAll packages installed successfully.\033[0m")
  } else if (!quiet) {
    .log("All required packages present.")
  }

  invisible(TRUE)
}

# ── Run at source time ────────────────────────────────────────────────────────
.stamina_biome_banner()
check_and_install_packages()
