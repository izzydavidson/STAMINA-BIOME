#!/bin/bash

# STAMINA-BIOME Shiny Frontend Launcher
# Launches the Shiny application with automatic browser opening

set -e

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if R is installed
if ! command -v R &> /dev/null; then
    echo "Error: R is not installed or not in PATH"
    echo "Please install R from https://cran.r-project.org/"
    exit 1
fi

# Check if required packages are installed
R --quiet --no-save << 'EOF'
required_packages <- c("shiny", "bslib", "jsonlite", "shinyjs", "shinydashboard", "sys")
missing_packages <- required_packages[!sapply(required_packages, requireNamespace, quietly = TRUE)]

if (length(missing_packages) > 0) {
  cat("Error: Missing required R packages:\n")
  cat(paste("  -", missing_packages), sep = "\n")
  cat("\nInstall with:\n")
  cat("install.packages(c('", paste(missing_packages, collapse = "', '"), "'))\n", sep = "")
  quit(status = 1)
}
EOF

if [ $? -ne 0 ]; then
    exit 1
fi

# Check if stamina-biome binary exists
STAMINA_BIOME_PATH="$SCRIPT_DIR/../stamina-biome"
if [ ! -f "$STAMINA_BIOME_PATH" ]; then
    echo "Warning: STAMINA-BIOME binary not found at $STAMINA_BIOME_PATH"
    echo "Please ensure STAMINA-BIOME is installed correctly"
fi

echo "Starting STAMINA-BIOME Shiny Frontend..."
echo "The application will open in your browser automatically"
echo "Press Ctrl+C to stop the server"
echo ""

# Launch Shiny app
cd "$SCRIPT_DIR"
R --quiet --no-save -e "shiny::runApp(launch.browser = TRUE)"
