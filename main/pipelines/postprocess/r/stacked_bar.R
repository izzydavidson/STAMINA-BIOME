#!/usr/bin/env Rscript

# =============================================================================
# STAMINA-BIOME R Postprocess: Stacked Bar Chart (Genus & Species)
# Generates both genus-level and species-level stacked bar charts
# Works with lr_meta, sr_meta (Kraken2), and sr_amp (QIIME2) outputs
# =============================================================================

suppressPackageStartupMessages({
  if (requireNamespace("jsonlite", quietly = TRUE)) {
    library(jsonlite)
  }
  if (requireNamespace("ggplot2", quietly = TRUE)) {
    library(ggplot2)
  }
  if (requireNamespace("dplyr", quietly = TRUE)) {
    library(dplyr)
  }
  if (requireNamespace("tidyr", quietly = TRUE)) {
    library(tidyr)
  }
  if (requireNamespace("RColorBrewer", quietly = TRUE)) {
    library(RColorBrewer)
  }
  if (requireNamespace("grid", quietly = TRUE)) {
    library(grid)
  }
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
  stop("Usage: stacked_bar.R --outputs_json <path> --out_dir <dir> [--params_json <json>] [--module <name>]")
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

cat("[stacked_bar] Module:", module_name, "\n")
cat("[stacked_bar] Output dir:", out_dir, "\n")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# ----------------------------
# Legend sizing controls
# ----------------------------
legend_title_size <- 9
legend_text_size <- 7
legend_key_cm <- 0.15
legend_spacing_y_cm <- 0.08
legend_columns <- 1
# ----------------------------

# Helper function to generate stacked bar chart
generate_stacked_bar <- function(data, taxon_col, abundance_col, rank_label, top_n, out_dir) {
  if (is.null(data) || nrow(data) == 0) {
    cat("[stacked_bar]", rank_label, ": No data available\n")
    return(FALSE)
  }

  # Get top N taxa
  top_taxa <- data %>%
    group_by(!!sym(taxon_col)) %>%
    summarise(total = sum(!!sym(abundance_col)), .groups = "drop") %>%
    arrange(desc(total)) %>%
    head(top_n) %>%
    pull(!!sym(taxon_col))

  if (length(top_taxa) == 0) {
    cat("[stacked_bar]", rank_label, ": No taxa found\n")
    return(FALSE)
  }

  # Label others
  data <- data %>%
    mutate(taxon_grouped = ifelse(!!sym(taxon_col) %in% top_taxa, !!sym(taxon_col), "Other"))

  # Aggregate with grouped taxa
  plot_data <- data %>%
    group_by(sample_id, taxon_grouped) %>%
    summarise(abundance = sum(!!sym(abundance_col)), .groups = "drop")

  # Normalize to proportions (ensure each sample sums to 1)
  plot_data <- plot_data %>%
    group_by(sample_id) %>%
    mutate(abundance = abundance / sum(abundance)) %>%
    ungroup()

  # Order taxa by total abundance (Other last)
  taxa_order <- plot_data %>%
    filter(taxon_grouped != "Other") %>%
    group_by(taxon_grouped) %>%
    summarise(total = sum(abundance), .groups = "drop") %>%
    arrange(desc(total)) %>%
    pull(taxon_grouped)

  taxa_order <- c(taxa_order, "Other")
  plot_data$taxon_grouped <- factor(plot_data$taxon_grouped, levels = rev(taxa_order))

  # Generate color palette
  n_colors <- length(unique(plot_data$taxon_grouped))
  if (n_colors <= 12) {
    colors <- RColorBrewer::brewer.pal(max(3, n_colors), "Set3")
  } else {
    colors <- colorRampPalette(RColorBrewer::brewer.pal(12, "Set3"))(n_colors)
  }

  # Create stacked bar chart
  p <- ggplot(plot_data, aes(x = sample_id, y = abundance, fill = taxon_grouped)) +
    geom_bar(stat = "identity", position = "stack") +
    scale_fill_manual(values = colors) +
    labs(
      title = paste(rank_label, "Relative Abundance (Top", top_n, ")"),
      x = "Sample",
      y = "Relative Abundance",
      fill = rank_label
    ) +
    theme_minimal() +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "right",
      legend.title = element_text(size = legend_title_size),
      legend.text = element_text(size = legend_text_size),
      legend.key.size = grid::unit(legend_key_cm, "cm"),
      legend.key.height = grid::unit(legend_key_cm, "cm"),
      legend.key.width = grid::unit(legend_key_cm, "cm"),
      legend.spacing.y = grid::unit(legend_spacing_y_cm, "cm"),
      legend.margin = margin(0, 0, 0, 0),
      legend.box.margin = margin(0, 0, 0, 0)
    ) +
    guides(
      fill = guide_legend(
        ncol = legend_columns,
        reverse = TRUE,
        keyheight = grid::unit(legend_key_cm, "cm"),
        keywidth = grid::unit(legend_key_cm, "cm")
      )
    )

  # Save PNG
  out_png <- file.path(out_dir, paste0("stacked_bar_", tolower(rank_label), ".png"))
  ggsave(out_png, p, width = 10, height = 7, dpi = 150, bg = "white")
  cat("[stacked_bar] Generated:", out_png, "\n")

  # Save PDF
  out_pdf <- file.path(out_dir, paste0("stacked_bar_", tolower(rank_label), ".pdf"))
  ggsave(out_pdf, p, width = 10, height = 7, bg = "white")
  cat("[stacked_bar] Generated:", out_pdf, "\n")

  return(TRUE)
}

# Get top_n parameter
top_n <- if (!is.null(params$top_n)) params$top_n else 15

# Track what we generated
generated_any <- FALSE

# Load Kraken2 data (lr_meta, sr_meta)
if (module_name %in% c("lr_meta", "sr_meta", "lr_amp") || is.null(module_name)) {
  postprocess_dir <- outputs$postprocess$dir
  if (!is.null(postprocess_dir)) {
    species_tidy <- file.path(postprocess_dir, "kraken_species_tidy.csv")
    genus_tidy <- file.path(postprocess_dir, "kraken_genus_tidy.csv")

    # Load genus data
    if (file.exists(genus_tidy)) {
      genus_data <- read.csv(genus_tidy, stringsAsFactors = FALSE)
      genus_data <- apply_sample_map(genus_data, "sample_id", params)
      cat("[stacked_bar] Loaded genus data:", nrow(genus_data), "rows,", length(unique(genus_data$genus)), "taxa\n")
      if (generate_stacked_bar(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
        generated_any <- TRUE
      }
    }

    # Load species data
    if (file.exists(species_tidy)) {
      species_data <- read.csv(species_tidy, stringsAsFactors = FALSE)
      species_data <- apply_sample_map(species_data, "sample_id", params)
      cat("[stacked_bar] Loaded species data:", nrow(species_data), "rows,", length(unique(species_data$species)), "taxa\n")
      if (generate_stacked_bar(species_data, "species", "fraction", "Species", top_n, out_dir)) {
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
      cat("[stacked_bar] Using QIIME2 exports\n")

      # Read feature table
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

        # Merge and reshape
        merged <- merge(table_df, tax_df[, c("FeatureID", "genus", "species")], by = "FeatureID")
        sample_cols <- setdiff(colnames(table_df), "FeatureID")

        if (length(sample_cols) > 0) {
          # Build genus data
          genus_long <- pivot_longer(
            merged,
            cols = all_of(sample_cols),
            names_to = "sample_id",
            values_to = "count"
          )
          genus_agg <- genus_long %>%
            group_by(sample_id, genus) %>%
            summarise(count = sum(count), .groups = "drop")
          genus_agg <- genus_agg %>%
            group_by(sample_id) %>%
            mutate(fraction = count / sum(count)) %>%
            ungroup()

          genus_agg_df <- apply_sample_map(as.data.frame(genus_agg), "sample_id", params)
          if (generate_stacked_bar(genus_agg_df, "genus", "fraction", "Genus", top_n, out_dir)) {
            generated_any <- TRUE
          }

          # Build species data (filter out Unassigned)
          species_long <- genus_long %>% filter(species != "Unassigned")
          if (nrow(species_long) > 0) {
            species_agg <- species_long %>%
              group_by(sample_id, species) %>%
              summarise(count = sum(count), .groups = "drop")
            species_agg <- species_agg %>%
              group_by(sample_id) %>%
              mutate(fraction = count / sum(count)) %>%
              ungroup()

            species_agg_df <- apply_sample_map(as.data.frame(species_agg), "sample_id", params)
            if (generate_stacked_bar(species_agg_df, "species", "fraction", "Species", top_n, out_dir)) {
              generated_any <- TRUE
            }
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
  cat("[stacked_bar] Emu dir:", emu_dir, "\n")
  if (!is.null(emu_dir) && dir.exists(emu_dir)) {
    cat("[stacked_bar] Loading Emu data from:", emu_dir, "\n")

    emu_files <- list.files(emu_dir, pattern = "_rel-abundance\\.tsv$",
                            recursive = TRUE, full.names = TRUE)

    if (length(emu_files) > 0) {
      cat("[stacked_bar] Found", length(emu_files), "Emu output files\n")

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
        cat("[stacked_bar] Emu genus data:", nrow(genus_data), "rows,",
            length(unique(genus_data$sample_id)), "samples\n")
        if (generate_stacked_bar(genus_data, "genus", "fraction", "Genus", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }

      if (length(species_rows) > 0) {
        species_data <- do.call(rbind, species_rows)
        species_data <- apply_sample_map(species_data, "sample_id", params)
        cat("[stacked_bar] Emu species data:", nrow(species_data), "rows,",
            length(unique(species_data$sample_id)), "samples\n")
        if (generate_stacked_bar(species_data, "species", "fraction", "Species", top_n, out_dir)) {
          generated_any <- TRUE
        }
      }
    }
  }
}

if (!generated_any) {
  cat("[stacked_bar] No data found for stacked bar chart\n")
}

cat("[stacked_bar] Complete\n")
