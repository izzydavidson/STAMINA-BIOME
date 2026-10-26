#!/usr/bin/env Rscript

# =============================================================================
# STAMINA-BIOME R Postprocess: Pie Chart (Genus & Species)
# Generates pie charts for each sample, arranged in a grid
# Works with both sr_amp (QIIME2) and sr_meta/lr_meta (Kraken2) outputs
# =============================================================================

suppressPackageStartupMessages({
  if (requireNamespace("jsonlite", quietly = TRUE)) library(jsonlite)
})

# Parse arguments
args <- commandArgs(trailingOnly = TRUE)
outputs_json <- NULL
out_dir <- NULL
params_json <- "{}"
module_name <- NULL

i <- 1
while (i <= length(args)) {
  if (args[i] == "--outputs_json" && i < length(args)) {
    outputs_json <- args[i + 1]
    i <- i + 2
  } else if (args[i] == "--out_dir" && i < length(args)) {
    out_dir <- args[i + 1]
    i <- i + 2
  } else if (args[i] == "--params_json" && i < length(args)) {
    params_json <- args[i + 1]
    i <- i + 2
  } else if (args[i] == "--module" && i < length(args)) {
    module_name <- args[i + 1]
    i <- i + 2
  } else {
    i <- i + 1
  }
}

if (is.null(outputs_json) || is.null(out_dir)) {
  stop("Usage: piechart.R --outputs_json <path> --out_dir <dir> [--params_json <json>] [--module <name>]")
}

# Load outputs.json
outputs <- fromJSON(outputs_json)
params <- tryCatch(fromJSON(params_json), error = function(e) list())

`%||%` <- function(x, y) if (is.null(x)) y else x

# Apply barcode → sample name mapping from sample sheet (if provided)
apply_sample_map <- function(df, sample_col, params) {
  tsv <- params$sample_sheet %||% NULL
  if (is.null(tsv) || !nzchar(tsv) || !file.exists(tsv)) return(df)
  sheet <- tryCatch(
    read.delim(tsv, stringsAsFactors = FALSE, na.strings = ""),
    error = function(e) NULL
  )
  if (is.null(sheet) || !all(c("barcode", "sample_name") %in% colnames(sheet))) return(df)
  name_map <- setNames(sheet$sample_name, sheet$barcode)
  bc_key   <- sub(".*_(barcode[0-9]+)$", "\\1", df[[sample_col]])
  mapped   <- name_map[bc_key]
  df[[sample_col]] <- ifelse(!is.na(mapped) & nzchar(mapped), mapped, df[[sample_col]])
  df
}

cat("[piechart] Module:", module_name, "\n")
cat("[piechart] Output dir:", out_dir, "\n")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Get module directory (where outputs.json lives) for resolving relative paths
module_dir <- dirname(outputs_json)

# Helper: Translate container path to host path
translate_path <- function(path) {
  if (is.null(path) || path == "") return(NULL)
  # If path starts with /work/, replace with module_dir parent structure
  if (grepl("^/work/", path)) {
    # Extract the relative part after the module directory
    # e.g., /work/outputs/run_id/module/results/postprocess -> results/postprocess
    parts <- strsplit(path, "/")[[1]]
    # Find where 'results' or similar starts
    results_idx <- which(parts == "results")
    if (length(results_idx) > 0) {
      rel_path <- paste(parts[results_idx[1]:length(parts)], collapse = "/")
      return(file.path(module_dir, rel_path))
    }
    # Fallback: try to find based on module name
    if (!is.null(module_name)) {
      module_idx <- which(parts == module_name)
      if (length(module_idx) > 0) {
        rel_path <- paste(parts[(module_idx[1]+1):length(parts)], collapse = "/")
        return(file.path(module_dir, rel_path))
      }
    }
  }
  # Return as-is if already a host path
  path
}

# Get top_n parameter
top_n <- if (!is.null(params$top_n)) params$top_n else 10

# ----------------------------
# Helper: Generate multi-sample pie chart grid
# ----------------------------
generate_piechart_grid <- function(data, sample_col, taxon_col, count_col, rank_label, top_n, out_dir) {
  if (is.null(data) || nrow(data) == 0) {
    cat("[piechart]", rank_label, ": No data available\n")
    return(FALSE)
  }

  # Get unique samples
  samples <- unique(data[[sample_col]])
  n_samples <- length(samples)

  if (n_samples == 0) {
    cat("[piechart]", rank_label, ": No samples found\n")
    return(FALSE)
  }

  cat("[piechart]", rank_label, ": Found", n_samples, "sample(s)\n")

  # Calculate grid dimensions — always reserve 1 extra slot for the legend
  total_panels <- n_samples + 1
  if (total_panels <= 2) {
    n_cols <- 2; n_rows <- 1
  } else if (total_panels <= 4) {
    n_cols <- 2; n_rows <- 2
  } else if (total_panels <= 6) {
    n_cols <- 3; n_rows <- 2
  } else if (total_panels <= 9) {
    n_cols <- 3; n_rows <- 3
  } else {
    n_cols <- 4; n_rows <- ceiling(total_panels / 4)
  }

  # Calculate figure dimensions based on grid size
  fig_width <- 400 * n_cols
  fig_height <- 450 * n_rows

  # Generate PNG
  out_png <- file.path(out_dir, paste0("piechart_", tolower(rank_label), ".png"))
  png(out_png, width = fig_width, height = fig_height, res = 150, bg = "white")

  # Set up multi-panel layout
  par(mfrow = c(n_rows, n_cols), mar = c(4, 1, 2, 1), oma = c(0, 0, 2, 0))

  # Generate a consistent color palette across all samples
  # First, get all unique taxa across all samples
  all_taxa_totals <- aggregate(data[[count_col]], by = list(taxon = data[[taxon_col]]), FUN = sum)
  all_taxa_totals <- all_taxa_totals[order(-all_taxa_totals$x), ]
  top_taxa_global <- head(all_taxa_totals$taxon, top_n)

  # Create color mapping for consistency across samples
  base_colors <- rainbow(length(top_taxa_global), s = 0.7, v = 0.8)
  names(base_colors) <- top_taxa_global
  other_color <- "gray70"

  # Process each sample
  for (sample_id in samples) {
    sample_data <- data[data[[sample_col]] == sample_id, ]

    # Aggregate by taxon for this sample
    taxon_totals <- aggregate(sample_data[[count_col]],
                              by = list(taxon = sample_data[[taxon_col]]),
                              FUN = sum)
    colnames(taxon_totals) <- c("taxon", "count")
    taxon_totals <- taxon_totals[order(-taxon_totals$count), ]

    if (nrow(taxon_totals) == 0) {
      # Empty plot with message
      plot.new()
      text(0.5, 0.5, "No data", cex = 1.2)
      title(sub = sample_id, line = 2, cex.sub = 1.0, font.sub = 2)
      next
    }

    # Get top taxa for this sample
    top_taxa <- head(taxon_totals, top_n)
    other_count <- sum(taxon_totals$count[-(1:min(top_n, nrow(taxon_totals)))])
    if (other_count > 0) {
      top_taxa <- rbind(top_taxa, data.frame(taxon = "Other", count = other_count))
    }

    total <- sum(top_taxa$count)
    top_taxa$pct <- round(100 * top_taxa$count / total, 1)

    # Assign colors - use global color mapping for consistency
    colors <- sapply(top_taxa$taxon, function(t) {
      if (t == "Other") return(other_color)
      if (t %in% names(base_colors)) return(base_colors[t])
      return("gray50")  # fallback for taxa not in global top
    })

    # Create labels - only show percentage on pie for larger slices
    labels_pie <- ifelse(top_taxa$pct >= 5, paste0(top_taxa$pct, "%"), "")

    # Draw pie chart
    pie(
      top_taxa$count,
      labels = labels_pie,
      col = colors,
      border = "white",
      cex = 0.7,
      radius = 0.85
    )

    # Add sample ID label at bottom
    title(sub = sample_id, line = 2, cex.sub = 1.1, font.sub = 2)
  }

  # Add overall title
  mtext(paste(rank_label, "Composition (Top", top_n, ")"), outer = TRUE, cex = 1.2, font = 2)

  # Add legend in the last available plot area (or create a new one if needed)
  plot.new()
  par(mar = c(1, 1, 2, 1))

  # Build legend with global top taxa
  legend_taxa <- c(top_taxa_global, "Other")
  legend_colors <- c(base_colors[top_taxa_global], other_color)

  legend(
    "center",
    legend = legend_taxa,
    fill = legend_colors,
    border = NA,
    cex = 0.8,
    bty = "n",
    title = paste(rank_label, "Legend"),
    title.cex = 1.0,
    title.font = 2
  )

  dev.off()
  cat("[piechart] Generated:", out_png, "\n")

  # Generate CSV with per-sample data
  out_csv <- file.path(out_dir, paste0("piechart_", tolower(rank_label), "_data.csv"))

  # Build summary data frame
  csv_rows <- list()
  for (sample_id in samples) {
    sample_data <- data[data[[sample_col]] == sample_id, ]
    taxon_totals <- aggregate(sample_data[[count_col]],
                              by = list(taxon = sample_data[[taxon_col]]),
                              FUN = sum)
    colnames(taxon_totals) <- c("taxon", "count")
    taxon_totals <- taxon_totals[order(-taxon_totals$count), ]

    top_taxa <- head(taxon_totals, top_n)
    other_count <- sum(taxon_totals$count[-(1:min(top_n, nrow(taxon_totals)))])
    if (other_count > 0) {
      top_taxa <- rbind(top_taxa, data.frame(taxon = "Other", count = other_count))
    }

    total <- sum(top_taxa$count)
    top_taxa$pct <- round(100 * top_taxa$count / total, 2)
    top_taxa$sample_id <- sample_id

    csv_rows[[length(csv_rows) + 1]] <- top_taxa
  }

  csv_data <- do.call(rbind, csv_rows)
  csv_data <- csv_data[, c("sample_id", "taxon", "count", "pct")]
  write.csv(csv_data, out_csv, row.names = FALSE)
  cat("[piechart] Generated:", out_csv, "\n")

  return(TRUE)
}

# Track what we generated
generated_any <- FALSE

# Load Kraken2 data (lr_meta, sr_meta)
if (module_name %in% c("sr_meta", "lr_meta", "lr_amp") || is.null(module_name)) {
  postprocess_dir <- translate_path(outputs$postprocess$dir)
  cat("[piechart] Postprocess dir:", postprocess_dir, "\n")
  if (!is.null(postprocess_dir) && dir.exists(postprocess_dir)) {
    species_tidy <- file.path(postprocess_dir, "kraken_species_tidy.csv")
    genus_tidy <- file.path(postprocess_dir, "kraken_genus_tidy.csv")

    # Load genus data
    if (file.exists(genus_tidy)) {
      genus_data <- read.csv(genus_tidy, stringsAsFactors = FALSE)
      genus_data <- apply_sample_map(genus_data, "sample_id", params)
      cat("[piechart] Loaded genus data:", nrow(genus_data), "rows,",
          length(unique(genus_data$genus)), "taxa,",
          length(unique(genus_data$sample_id)), "samples\n")
      if (generate_piechart_grid(genus_data, "sample_id", "genus", "reads", "Genus", top_n, out_dir)) {
        generated_any <- TRUE
      }
    }

    # Load species data
    if (file.exists(species_tidy)) {
      species_data <- read.csv(species_tidy, stringsAsFactors = FALSE)
      species_data <- apply_sample_map(species_data, "sample_id", params)
      cat("[piechart] Loaded species data:", nrow(species_data), "rows,",
          length(unique(species_data$species)), "taxa,",
          length(unique(species_data$sample_id)), "samples\n")
      if (generate_piechart_grid(species_data, "sample_id", "species", "reads", "Species", top_n, out_dir)) {
        generated_any <- TRUE
      }
    }
  }
}

# Load QIIME2 data (sr_amp) - generates genus and species from taxonomy
if (!generated_any && (module_name == "sr_amp" || is.null(module_name))) {
  qiime2_exports <- outputs$qiime2_exports
  if (!is.null(qiime2_exports)) {
    table_tsv <- qiime2_exports$table_tsv
    taxonomy_tsv <- qiime2_exports$taxonomy_tsv

    if (!is.null(table_tsv) && file.exists(table_tsv) &&
        !is.null(taxonomy_tsv) && file.exists(taxonomy_tsv)) {
      cat("[piechart] Using QIIME2 exports\n")

      lines <- readLines(table_tsv)
      header_idx <- which(grepl("^#OTU ID", lines))[1]
      if (!is.na(header_idx)) {
        table_df <- read.delim(
          text = paste(lines[header_idx:length(lines)], collapse = "\n"),
          sep = "\t",
          stringsAsFactors = FALSE,
          check.names = FALSE
        )
        colnames(table_df)[1] <- "FeatureID"

        tax_df <- read.delim(taxonomy_tsv, stringsAsFactors = FALSE, check.names = FALSE)
        colnames(tax_df)[1] <- "FeatureID"

        # Parse taxonomy to extract genus and species separately
        parse_taxonomy <- function(taxon) {
          if (is.na(taxon) || taxon == "") return(list(genus = "Unassigned", species = "Unassigned"))
          parts <- strsplit(taxon, ";")[[1]]
          parts <- trimws(parts)
          genus <- "Unassigned"
          species <- "Unassigned"
          for (p in parts) {
            if (grepl("^g__", p)) genus <- sub("^g__", "", p)
            if (grepl("^s__", p)) species <- sub("^s__", "", p)
            if (grepl("^D_5__", p)) genus <- sub("^D_5__", "", p)
            if (grepl("^D_6__", p)) species <- sub("^D_6__", "", p)
          }
          if (genus == "") genus <- "Unassigned"
          if (species == "" || species == genus) species <- "Unassigned"
          list(genus = genus, species = species)
        }

        parsed <- lapply(tax_df$Taxon, parse_taxonomy)
        tax_df$genus <- vapply(parsed, function(x) x$genus, character(1))
        tax_df$species <- vapply(parsed, function(x) x$species, character(1))

        sample_cols <- setdiff(colnames(table_df), "FeatureID")

        # Build tidy data for genus and species with sample_id
        genus_rows <- list()
        species_rows <- list()
        for (r in seq_len(nrow(table_df))) {
          fid <- table_df$FeatureID[r]
          idx <- match(fid, tax_df$FeatureID)
          g <- if (!is.na(idx)) tax_df$genus[idx] else "Unassigned"
          s <- if (!is.na(idx)) tax_df$species[idx] else "Unassigned"

          for (sc in sample_cols) {
            count <- suppressWarnings(as.numeric(table_df[r, sc]))
            if (!is.na(count) && count > 0) {
              genus_rows[[length(genus_rows) + 1]] <- data.frame(
                sample_id = sc, genus = g, reads = count, stringsAsFactors = FALSE)
              if (s != "Unassigned") {
                species_rows[[length(species_rows) + 1]] <- data.frame(
                  sample_id = sc, species = s, reads = count, stringsAsFactors = FALSE)
              }
            }
          }
        }

        # Generate genus pie chart grid
        if (length(genus_rows) > 0) {
          genus_data <- do.call(rbind, genus_rows)
          genus_data <- apply_sample_map(genus_data, "sample_id", params)
          cat("[piechart] QIIME2 genus data:", nrow(genus_data), "rows,",
              length(unique(genus_data$sample_id)), "samples\n")
          if (generate_piechart_grid(genus_data, "sample_id", "genus", "reads", "Genus", top_n, out_dir)) {
            generated_any <- TRUE
          }
        }

        # Generate species pie chart grid
        if (length(species_rows) > 0) {
          species_data <- do.call(rbind, species_rows)
          species_data <- apply_sample_map(species_data, "sample_id", params)
          cat("[piechart] QIIME2 species data:", nrow(species_data), "rows,",
              length(unique(species_data$sample_id)), "samples\n")
          if (generate_piechart_grid(species_data, "sample_id", "species", "reads", "Species", top_n, out_dir)) {
            generated_any <- TRUE
          }
        }
      }
    }
  }
}

# Load Emu data (lr_amp) - if no Kraken data available
if (!generated_any && module_name == "lr_amp") {
  emu_dir <- translate_path(outputs$emu$dir)
  cat("[piechart] Emu dir:", emu_dir, "\n")
  if (!is.null(emu_dir) && dir.exists(emu_dir)) {
    cat("[piechart] Loading Emu data from:", emu_dir, "\n")

    # Find all rel-abundance files
    emu_files <- list.files(emu_dir, pattern = "_rel-abundance\\.tsv$",
                            recursive = TRUE, full.names = TRUE)

    if (length(emu_files) > 0) {
      cat("[piechart] Found", length(emu_files), "Emu output files\n")

      # Load and combine all Emu outputs
      genus_rows <- list()
      species_rows <- list()

      for (emu_file in emu_files) {
        # Extract sample ID from path (parent directory name or filename)
        sample_id <- basename(dirname(emu_file))
        if (sample_id == "." || sample_id == emu_dir) {
          # Use filename as sample ID
          sample_id <- sub("_rel-abundance\\.tsv$", "", basename(emu_file))
          sample_id <- sub("\\..*$", "", sample_id)  # Remove extensions
        }

        emu_data <- tryCatch(
          read.delim(emu_file, stringsAsFactors = FALSE),
          error = function(e) NULL
        )

        if (!is.null(emu_data) && nrow(emu_data) > 0) {
          # Emu outputs have 'abundance' (relative) and taxonomic columns
          if ("genus" %in% colnames(emu_data) && "abundance" %in% colnames(emu_data)) {
            for (r in seq_len(nrow(emu_data))) {
              if (!is.na(emu_data$abundance[r]) && emu_data$abundance[r] > 0) {
                genus_rows[[length(genus_rows) + 1]] <- data.frame(
                  sample_id = sample_id,
                  genus = emu_data$genus[r],
                  reads = emu_data$abundance[r] * 10000,  # Convert to pseudo-counts
                  stringsAsFactors = FALSE
                )
              }
            }
          }

          if ("species" %in% colnames(emu_data) && "abundance" %in% colnames(emu_data)) {
            for (r in seq_len(nrow(emu_data))) {
              if (!is.na(emu_data$abundance[r]) && emu_data$abundance[r] > 0 &&
                  !is.na(emu_data$species[r]) && emu_data$species[r] != "") {
                species_rows[[length(species_rows) + 1]] <- data.frame(
                  sample_id = sample_id,
                  species = emu_data$species[r],
                  reads = emu_data$abundance[r] * 10000,  # Convert to pseudo-counts
                  stringsAsFactors = FALSE
                )
              }
            }
          }
        }
      }

      # Generate genus pie chart grid from Emu data
      if (length(genus_rows) > 0) {
        genus_data <- do.call(rbind, genus_rows)
        genus_data <- apply_sample_map(genus_data, "sample_id", params)
        cat("[piechart] Emu genus data:", nrow(genus_data), "rows,",
            length(unique(genus_data$sample_id)), "samples\n")
        if (generate_piechart_grid(genus_data, "sample_id", "genus", "reads", "Genus", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }

      # Generate species pie chart grid from Emu data
      if (length(species_rows) > 0) {
        species_data <- do.call(rbind, species_rows)
        species_data <- apply_sample_map(species_data, "sample_id", params)
        cat("[piechart] Emu species data:", nrow(species_data), "rows,",
            length(unique(species_data$sample_id)), "samples\n")
        if (generate_piechart_grid(species_data, "sample_id", "species", "reads", "Species", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }
    }
  }
}

if (!generated_any) {
  cat("[piechart] No suitable data found for plotting\n")
}

cat("[piechart] Complete\n")
