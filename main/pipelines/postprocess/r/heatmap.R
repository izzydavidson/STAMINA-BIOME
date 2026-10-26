#!/usr/bin/env Rscript

# =============================================================================
# STAMINA-BIOME R Postprocess: Heatmap (Genus & Species)
# Generates both genus-level and species-level heatmaps
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
  stop("Usage: heatmap.R --outputs_json <path> --out_dir <dir> [--params_json <json>] [--module <name>]")
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

cat("[heatmap] Module:", module_name, "\n")
cat("[heatmap] Output dir:", out_dir, "\n")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# ----------------------------
# Legend sizing controls
# ----------------------------
legend_axis_cex <- 0.5
legend_title_cex <- 0.5
legend_title_line <- 1
# ----------------------------

# Helper function to generate heatmap
generate_heatmap <- function(data, taxon_col, abundance_col, rank_label, top_n, out_dir) {
  if (is.null(data) || nrow(data) == 0) {
    cat("[heatmap]", rank_label, ": No data available\n")
    return(FALSE)
  }

  # Get top N taxa by total abundance
  taxon_totals <- aggregate(data[[abundance_col]], by = list(taxon = data[[taxon_col]]), FUN = sum)
  colnames(taxon_totals) <- c("taxon", "total")
  taxon_totals <- taxon_totals[order(-taxon_totals$total), ]
  top_taxa <- head(taxon_totals$taxon, top_n)

  # Filter to top taxa only
  data_top <- data[data[[taxon_col]] %in% top_taxa, ]

  if (nrow(data_top) == 0) {
    cat("[heatmap]", rank_label, ": No data after filtering\n")
    return(FALSE)
  }

  # Create wide matrix for heatmap
  samples <- unique(data_top$sample_id)
  taxa <- top_taxa

  n_samples <- length(samples)
  n_taxa <- length(taxa)

  if (n_samples == 0 || n_taxa == 0) {
    cat("[heatmap]", rank_label, ": No samples or taxa found\n")
    return(FALSE)
  }

  mat <- matrix(0, nrow = n_taxa, ncol = n_samples)
  rownames(mat) <- taxa
  colnames(mat) <- samples

  for (r in seq_len(nrow(data_top))) {
    s <- data_top$sample_id[r]
    t <- data_top[[taxon_col]][r]
    if (t %in% taxa && s %in% samples) {
      mat[t, s] <- data_top[[abundance_col]][r]
    }
  }

  # Generate heatmap
  out_png <- file.path(out_dir, paste0("heatmap_", tolower(rank_label), ".png"))

  plot_width <- max(1100, n_samples * 120 + 350)
  plot_height <- max(800, n_taxa * 30 + 200)

  png(out_png, width = plot_width, height = plot_height, res = 150, bg = "white")

  layout(matrix(c(1, 2), nrow = 1), widths = c(4, 1))

  par(mar = c(8, 12, 3, 1))

  # Log1p-transform for display: log1p(x*100)/log1p(100) maps [0,1] -> [0,1]
  # with strong expansion at low values so tiny abundances are still visually distinct.
  # e.g. 1% -> 15% of color scale, 5% -> 39%, 10% -> 52%, 50% -> 85%
  # Colorbar labels show original (untransformed) values.
  mat_display <- log1p(mat * 100) / log1p(100)

  # Viridis approximation — perceptually uniform, strong contrast across full 0-1 range
  n_colors <- 100
  colors <- colorRampPalette(c(
    "#440154", "#482878", "#3e4989", "#31688e",
    "#26828e", "#1f9e89", "#35b779", "#6dcd59",
    "#b4de2c", "#fde725"
  ))(n_colors)

  image(
    1:n_samples, 1:n_taxa, t(mat_display),
    col = colors,
    xlab = "", ylab = "",
    axes = FALSE,
    zlim = c(0, 1),
    main = paste(rank_label, "Heatmap (Top", top_n, ")")
  )

  axis(1, at = 1:n_samples, labels = colnames(mat), las = 2, cex.axis = 0.7)
  axis(2, at = 1:n_taxa, labels = rownames(mat), las = 1, cex.axis = 0.6)

  abline(h = 0.5:(n_taxa + 0.5), col = "gray80", lwd = 0.5)
  abline(v = 0.5:(n_samples + 0.5), col = "gray80", lwd = 0.5)

  # Colorbar: ticks at log1p-transformed positions, labels show original values
  par(mar = c(8, 1, 3, 3))
  image(
    1, seq(0, 1, length.out = n_colors), t(matrix(1:n_colors)),
    col = colors,
    xlab = "", ylab = "",
    axes = FALSE
  )
  colorbar_orig   <- c(0, 0.01, 0.05, 0.10, 0.25, 0.50, 1.00)
  colorbar_at     <- log1p(colorbar_orig * 100) / log1p(100)
  colorbar_labels <- format(colorbar_orig, nsmall = 2)
  axis(
    4,
    at = colorbar_at,
    labels = colorbar_labels,
    las = 1,
    cex.axis = legend_axis_cex
  )
  mtext("Rel. Abundance", side = 4, line = legend_title_line, cex = legend_title_cex)

  dev.off()
  cat("[heatmap] Generated:", out_png, "\n")

  # Generate CSV
  out_csv <- file.path(out_dir, paste0("heatmap_", tolower(rank_label), "_data.csv"))
  write.csv(as.data.frame(mat), out_csv, row.names = TRUE)
  cat("[heatmap] Generated:", out_csv, "\n")

  return(TRUE)
}

# Get top_n parameter — minimum 5 to prevent n_samples being mistaken for top_n
top_n <- if (!is.null(params$top_n) && is.numeric(params$top_n) && params$top_n >= 5) params$top_n else 25

# Track what we generated
generated_any <- FALSE

# Load Kraken2 data (lr_meta, sr_meta)
if (module_name %in% c("sr_meta", "lr_meta", "lr_amp") || is.null(module_name)) {
  postprocess_dir <- outputs$postprocess$dir
  if (!is.null(postprocess_dir)) {
    species_tidy <- file.path(postprocess_dir, "kraken_species_tidy.csv")
    genus_tidy <- file.path(postprocess_dir, "kraken_genus_tidy.csv")

    # Load genus data
    if (file.exists(genus_tidy)) {
      genus_data <- read.csv(genus_tidy, stringsAsFactors = FALSE)
      genus_data <- apply_sample_map(genus_data, "sample_id", params)
      cat("[heatmap] Loaded genus data:", nrow(genus_data), "rows,", length(unique(genus_data$genus)), "taxa\n")
      if (generate_heatmap(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
        generated_any <- TRUE
      }
    }

    # Load species data
    if (file.exists(species_tidy)) {
      species_data <- read.csv(species_tidy, stringsAsFactors = FALSE)
      species_data <- apply_sample_map(species_data, "sample_id", params)
      cat("[heatmap] Loaded species data:", nrow(species_data), "rows,", length(unique(species_data$species)), "taxa\n")
      if (generate_heatmap(species_data, "species", "fraction", "Species", top_n, out_dir)) {
        generated_any <- TRUE
      }
    }
  }
}

# Load QIIME2 data (sr_amp)
if (!generated_any && (module_name == "sr_amp" || is.null(module_name))) {
  qiime2_exports <- outputs$qiime2_exports
  if (!is.null(qiime2_exports)) {
    table_tsv <- qiime2_exports$table_tsv
    taxonomy_tsv <- qiime2_exports$taxonomy_tsv

    if (!is.null(table_tsv) && file.exists(table_tsv) &&
        !is.null(taxonomy_tsv) && file.exists(taxonomy_tsv)) {
      cat("[heatmap] Using QIIME2 exports\n")

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

        # Parse taxonomy
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

        # Build tidy data
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
              genus_rows[[length(genus_rows) + 1]] <- data.frame(sample_id = sc, genus = g, count = count, stringsAsFactors = FALSE)
              if (s != "Unassigned") {
                species_rows[[length(species_rows) + 1]] <- data.frame(sample_id = sc, species = s, count = count, stringsAsFactors = FALSE)
              }
            }
          }
        }

        # Process genus data
        if (length(genus_rows) > 0) {
          genus_data <- do.call(rbind, genus_rows)
          genus_data <- aggregate(count ~ sample_id + genus, data = genus_data, FUN = sum)
          totals <- aggregate(count ~ sample_id, data = genus_data, FUN = sum)
          colnames(totals)[2] <- "total"
          genus_data <- merge(genus_data, totals, by = "sample_id")
          genus_data$fraction <- genus_data$count / genus_data$total
          genus_data <- apply_sample_map(genus_data, "sample_id", params)
          if (generate_heatmap(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
            generated_any <- TRUE
          }
        }

        # Process species data
        if (length(species_rows) > 0) {
          species_data <- do.call(rbind, species_rows)
          species_data <- aggregate(count ~ sample_id + species, data = species_data, FUN = sum)
          totals <- aggregate(count ~ sample_id, data = species_data, FUN = sum)
          colnames(totals)[2] <- "total"
          species_data <- merge(species_data, totals, by = "sample_id")
          species_data$fraction <- species_data$count / species_data$total
          species_data <- apply_sample_map(species_data, "sample_id", params)
          if (generate_heatmap(species_data, "species", "fraction", "Species", top_n, out_dir)) {
            generated_any <- TRUE
          }
        }
      }
    }
  }
}

# Load Emu data (lr_amp) - if no Kraken data available
if (!generated_any && module_name == "lr_amp") {
  # Helper function to translate container paths to host paths
  translate_path <- function(path) {
    if (is.null(path) || path == "") return(NULL)
    if (grepl("^/work/", path)) {
      module_dir <- dirname(outputs_json)
      parts <- strsplit(path, "/")[[1]]
      results_idx <- which(parts == "results")
      if (length(results_idx) > 0) {
        rel_path <- paste(parts[results_idx[1]:length(parts)], collapse = "/")
        return(file.path(module_dir, rel_path))
      }
      if (!is.null(module_name)) {
        module_idx <- which(parts == module_name)
        if (length(module_idx) > 0) {
          rel_path <- paste(parts[(module_idx[1]+1):length(parts)], collapse = "/")
          return(file.path(module_dir, rel_path))
        }
      }
    }
    path
  }

  emu_dir <- translate_path(outputs$emu$dir)
  cat("[heatmap] Emu dir:", emu_dir, "\n")
  if (!is.null(emu_dir) && dir.exists(emu_dir)) {
    cat("[heatmap] Loading Emu data from:", emu_dir, "\n")

    emu_files <- list.files(emu_dir, pattern = "_rel-abundance\\.tsv$",
                            recursive = TRUE, full.names = TRUE)

    if (length(emu_files) > 0) {
      cat("[heatmap] Found", length(emu_files), "Emu output files\n")

      genus_rows <- list()
      species_rows <- list()

      for (emu_file in emu_files) {
        sample_id <- basename(dirname(emu_file))
        if (sample_id == "." || sample_id == emu_dir) {
          sample_id <- sub("_rel-abundance\\.tsv$", "", basename(emu_file))
          sample_id <- sub("\\..*$", "", sample_id)
        }

        emu_data <- tryCatch(
          read.delim(emu_file, stringsAsFactors = FALSE),
          error = function(e) NULL
        )

        if (!is.null(emu_data) && nrow(emu_data) > 0) {
          if ("genus" %in% colnames(emu_data) && "abundance" %in% colnames(emu_data)) {
            for (r in seq_len(nrow(emu_data))) {
              if (!is.na(emu_data$abundance[r]) && emu_data$abundance[r] > 0 &&
                  !is.na(emu_data$genus[r]) && emu_data$genus[r] != "") {
                genus_rows[[length(genus_rows) + 1]] <- data.frame(
                  sample_id = sample_id,
                  genus = emu_data$genus[r],
                  fraction = emu_data$abundance[r],
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
                  fraction = emu_data$abundance[r],
                  stringsAsFactors = FALSE
                )
              }
            }
          }
        }
      }

      if (length(genus_rows) > 0) {
        genus_data <- do.call(rbind, genus_rows)
        genus_data <- apply_sample_map(genus_data, "sample_id", params)
        cat("[heatmap] Emu genus data:", nrow(genus_data), "rows,",
            length(unique(genus_data$sample_id)), "samples\n")
        if (generate_heatmap(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }

      if (length(species_rows) > 0) {
        species_data <- do.call(rbind, species_rows)
        species_data <- apply_sample_map(species_data, "sample_id", params)
        cat("[heatmap] Emu species data:", nrow(species_data), "rows,",
            length(unique(species_data$sample_id)), "samples\n")
        if (generate_heatmap(species_data, "species", "fraction", "Species", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }
    }
  }
}

if (!generated_any) {
  cat("[heatmap] No suitable data found for plotting\n")
}

cat("[heatmap] Complete\n")
