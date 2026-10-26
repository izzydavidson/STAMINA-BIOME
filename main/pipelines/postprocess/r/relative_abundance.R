#!/usr/bin/env Rscript

# =============================================================================
# STAMINA-BIOME R Postprocess: Relative Abundance Stacked Bar Chart (Genus & Species)
# Generates both genus-level and species-level stacked bar charts
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
  stop("Usage: relative_abundance.R --outputs_json <path> --out_dir <dir> [--params_json <json>] [--module <name>]")
}

# Load outputs.json
outputs <- fromJSON(outputs_json)
params <- tryCatch(fromJSON(params_json), error = function(e) list())

cat("[relative_abundance] Module:", module_name, "\n")
cat("[relative_abundance] Output dir:", out_dir, "\n")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# ----------------------------
# Legend sizing controls
# ----------------------------
legend_cex <- 0.65
legend_inset <- c(-0.60, 0)
legend_ncol <- 1
legend_x <- "topright"
# ----------------------------

# Helper function to generate relative abundance bar chart
generate_rel_abundance <- function(data, taxon_col, abundance_col, rank_label, top_n, out_dir) {
  if (is.null(data) || nrow(data) == 0) {
    cat("[relative_abundance]", rank_label, ": No data available\n")
    return(FALSE)
  }

  # Get top N taxa by total abundance
  taxon_totals <- aggregate(data[[abundance_col]], by = list(taxon = data[[taxon_col]]), FUN = sum)
  colnames(taxon_totals) <- c("taxon", "total")
  taxon_totals <- taxon_totals[order(-taxon_totals$total), ]
  top_taxa <- head(taxon_totals$taxon, top_n)

  # Label others
  data$taxon_plot <- ifelse(data[[taxon_col]] %in% top_taxa, data[[taxon_col]], "Other")

  # Aggregate with grouped taxa
  plot_data <- aggregate(
    data[[abundance_col]],
    by = list(sample = data$sample_id, taxon = data$taxon_plot),
    FUN = sum
  )
  colnames(plot_data) <- c("sample", "taxon", "abundance")

  # Normalize to relative abundance per sample
  sample_totals <- aggregate(abundance ~ sample, data = plot_data, FUN = sum)
  colnames(sample_totals)[2] <- "total"
  plot_data <- merge(plot_data, sample_totals, by = "sample")
  plot_data$abundance <- plot_data$abundance / plot_data$total

  # Order taxa by total abundance (Other last)
  taxa_order <- unique(plot_data$taxon)
  taxa_order <- c(setdiff(taxa_order, "Other"), "Other")[c(setdiff(taxa_order, "Other"), "Other") %in% taxa_order]
  plot_data$taxon <- factor(plot_data$taxon, levels = taxa_order)

  samples <- unique(plot_data$sample)
  n_samples <- length(samples)
  n_taxa <- length(taxa_order)

  if (n_samples == 0 || n_taxa == 0) {
    cat("[relative_abundance]", rank_label, ": No samples or taxa found\n")
    return(FALSE)
  }

  colors <- rainbow(n_taxa, s = 0.7, v = 0.8)
  if ("Other" %in% taxa_order) {
    colors[which(taxa_order == "Other")] <- "gray70"
  }

  # Generate PNG
  out_png <- file.path(out_dir, paste0("relative_abundance_", tolower(rank_label), ".png"))
  png(out_png, width = max(800, n_samples * 80), height = 600, res = 150, bg = "white")

  par(mar = c(8, 4, 3, 12), xpd = TRUE)

  mat <- matrix(0, nrow = n_taxa, ncol = n_samples)
  rownames(mat) <- taxa_order
  colnames(mat) <- samples

  for (r in seq_len(nrow(plot_data))) {
    s <- as.character(plot_data$sample[r])
    t <- as.character(plot_data$taxon[r])
    mat[t, s] <- plot_data$abundance[r]
  }

  barplot(
    mat,
    col = colors,
    border = NA,
    las = 2,
    cex.names = 0.7,
    ylab = "Relative Abundance",
    main = paste(rank_label, "Relative Abundance (Top", top_n, ")"),
    ylim = c(0, 1)
  )

  legend(
    legend_x,
    inset = legend_inset,
    legend = taxa_order,
    fill = colors,
    border = NA,
    cex = legend_cex,
    bty = "n",
    ncol = legend_ncol,
    title = rank_label
  )

  dev.off()
  cat("[relative_abundance] Generated:", out_png, "\n")

  # Generate CSV
  out_csv <- file.path(out_dir, paste0("relative_abundance_", tolower(rank_label), "_data.csv"))
  write.csv(plot_data[, c("sample", "taxon", "abundance")], out_csv, row.names = FALSE)
  cat("[relative_abundance] Generated:", out_csv, "\n")

  return(TRUE)
}

# Get top_n parameter
top_n <- if (!is.null(params$top_n)) params$top_n else 15

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
      cat("[relative_abundance] Loaded genus data:", nrow(genus_data), "rows,", length(unique(genus_data$genus)), "taxa\n")
      if (generate_rel_abundance(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
        generated_any <- TRUE
      }
    }

    # Load species data
    if (file.exists(species_tidy)) {
      species_data <- read.csv(species_tidy, stringsAsFactors = FALSE)
      cat("[relative_abundance] Loaded species data:", nrow(species_data), "rows,", length(unique(species_data$species)), "taxa\n")
      if (generate_rel_abundance(species_data, "species", "fraction", "Species", top_n, out_dir)) {
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
      cat("[relative_abundance] Using QIIME2 exports\n")

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
          if (generate_rel_abundance(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
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
          if (generate_rel_abundance(species_data, "species", "fraction", "Species", top_n, out_dir)) {
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
  cat("[relative_abundance] Emu dir:", emu_dir, "\n")
  if (!is.null(emu_dir) && dir.exists(emu_dir)) {
    cat("[relative_abundance] Loading Emu data from:", emu_dir, "\n")

    emu_files <- list.files(emu_dir, pattern = "_rel-abundance\\.tsv$",
                            recursive = TRUE, full.names = TRUE)

    if (length(emu_files) > 0) {
      cat("[relative_abundance] Found", length(emu_files), "Emu output files\n")

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
        cat("[relative_abundance] Emu genus data:", nrow(genus_data), "rows,",
            length(unique(genus_data$sample_id)), "samples\n")
        if (generate_rel_abundance(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }

      if (length(species_rows) > 0) {
        species_data <- do.call(rbind, species_rows)
        cat("[relative_abundance] Emu species data:", nrow(species_data), "rows,",
            length(unique(species_data$sample_id)), "samples\n")
        if (generate_rel_abundance(species_data, "species", "fraction", "Species", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }
    }
  }
}

if (!generated_any) {
  cat("[relative_abundance] No suitable data found for plotting\n")
}

cat("[relative_abundance] Complete\n")
