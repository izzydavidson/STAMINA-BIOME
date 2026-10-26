#!/usr/bin/env Rscript

# STAMINA-BIOME Shiny Frontend - Dependency Installer
# Installs all required R packages for the Shiny application

cat("STAMINA-BIOME Shiny Frontend - Installing Dependencies\n")
cat("==================================================\n\n")

# List of required packages
required_packages <- c(
  "shiny",
  "bslib",
  "jsonlite",
  "shinyjs",
  "shinydashboard",
  "sys"
)

# Check which packages are already installed
installed <- installed.packages()[, "Package"]
to_install <- required_packages[!required_packages %in% installed]

if (length(to_install) == 0) {
  cat("All required packages are already installed!\n")
  cat("\nInstalled packages:\n")
  cat(paste("  ✓", required_packages), sep = "\n")
  cat("\nYou can now launch the app with: ./launch.sh\n")
  quit(save = "no", status = 0)
}

# Install missing packages
cat("The following packages will be installed:\n")
cat(paste("  -", to_install), sep = "\n")
cat("\nInstalling packages...\n")
install.packages(to_install, repos = "https://cloud.r-project.org/", quiet = FALSE)

# Verify installation
cat("\nVerifying installation...\n")
verification <- sapply(required_packages, function(pkg) {
  result <- requireNamespace(pkg, quietly = TRUE)
  if (result) {
    cat(paste0("  ✓ ", pkg, "\n"))
  } else {
    cat(paste0("  ✗ ", pkg, " (FAILED)\n"))
  }
  result
})

if (all(verification)) {
  cat("\n✓ All packages installed successfully!\n")
  cat("\nYou can now launch the app with: ./launch.sh\n")
  quit(save = "no", status = 0)
} else {
  cat("\n✗ Some packages failed to install. Please install them manually.\n")
  quit(save = "no", status = 1)
}
