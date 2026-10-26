#!/usr/bin/env Rscript
# =============================================================================
# Ground truth stacked bar chart — matches STAMINA-BIOME pipeline visual style
# Reads CAMI taxonomic_profile_0.txt and generates species + genus bar charts
# =============================================================================

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(RColorBrewer)
  library(grid)
})

# Override paths via CLI: Rscript ground_truth_stacked_bar.R [gt_path] [out_dir]
args_cli     <- commandArgs(trailingOnly = TRUE)
REPO_ROOT    <- normalizePath(file.path(dirname(sys.frame(1)$ofile %||% "."), ".."), mustWork = FALSE)
`%||%`       <- function(a, b) if (length(a) > 0) a else b
GROUND_TRUTH <- if (length(args_cli) >= 1) args_cli[1] else file.path(path.expand("~"), "camisim_output/mock_metagenome_generic/nanopore/taxonomic_profile_0.txt")
OUT_DIR      <- if (length(args_cli) >= 2) args_cli[2] else file.path(REPO_ROOT, "validation")

TOP_N <- 15

# ── Parse CAMI taxonomic profile ─────────────────────────────────────────────
parse_cami_profile <- function(path, rank_filter) {
  lines <- readLines(path)
  rows <- list()
  for (line in lines) {
    if (startsWith(line, "@") || !nzchar(trimws(line))) next
    parts <- strsplit(line, "\t")[[1]]
    if (length(parts) < 5) next
    taxid <- parts[1]; rank <- parts[2]; taxpathsn <- parts[4]; pct <- parts[5]
    if (rank != rank_filter) next
    name <- trimws(tail(strsplit(taxpathsn, "\\|")[[1]], 1))
    rows[[length(rows) + 1]] <- data.frame(
      taxon    = name,
      fraction = as.numeric(pct) / 100,
      stringsAsFactors = FALSE
    )
  }
  if (length(rows) == 0) return(NULL)
  do.call(rbind, rows)
}

# ── Stacked bar — exactly matching pipeline generate_stacked_bar() ────────────
legend_title_size  <- 9
legend_text_size   <- 7
legend_key_cm      <- 0.15
legend_spacing_y_cm <- 0.08
legend_columns     <- 1

make_stacked_bar <- function(df, taxon_col, rank_label, top_n, out_dir, label) {

  # Top N
  top_taxa <- df %>%
    arrange(desc(fraction)) %>%
    head(top_n) %>%
    pull(!!sym(taxon_col))

  df <- df %>%
    mutate(
      taxon_grouped = ifelse(!!sym(taxon_col) %in% top_taxa, !!sym(taxon_col), "Other"),
      sample_id     = label
    )

  plot_data <- df %>%
    group_by(sample_id, taxon_grouped) %>%
    summarise(abundance = sum(fraction), .groups = "drop") %>%
    group_by(sample_id) %>%
    mutate(abundance = abundance / sum(abundance)) %>%
    ungroup()

  taxa_order <- plot_data %>%
    filter(taxon_grouped != "Other") %>%
    group_by(taxon_grouped) %>%
    summarise(total = sum(abundance), .groups = "drop") %>%
    arrange(desc(total)) %>%
    pull(taxon_grouped)
  taxa_order <- c(taxa_order, "Other")

  plot_data$taxon_grouped <- factor(plot_data$taxon_grouped, levels = rev(taxa_order))

  n_colors <- length(unique(plot_data$taxon_grouped))
  if (n_colors <= 12) {
    colors <- RColorBrewer::brewer.pal(max(3, n_colors), "Set3")
  } else {
    colors <- colorRampPalette(RColorBrewer::brewer.pal(12, "Set3"))(n_colors)
  }

  p <- ggplot(plot_data, aes(x = sample_id, y = abundance, fill = taxon_grouped)) +
    geom_bar(stat = "identity", position = "stack") +
    scale_fill_manual(values = colors) +
    labs(
      title = paste(rank_label, "Relative Abundance (Top", top_n, ")"),
      x     = "Sample",
      y     = "Relative Abundance",
      fill  = rank_label
    ) +
    theme_minimal() +
    theme(
      axis.text.x      = element_text(angle = 45, hjust = 1),
      legend.position  = "right",
      legend.title     = element_text(size = legend_title_size),
      legend.text      = element_text(size = legend_text_size),
      legend.key.size  = unit(legend_key_cm, "cm"),
      legend.key.height = unit(legend_key_cm, "cm"),
      legend.key.width  = unit(legend_key_cm, "cm"),
      legend.spacing.y  = unit(legend_spacing_y_cm, "cm"),
      legend.margin     = margin(0, 0, 0, 0),
      legend.box.margin = margin(0, 0, 0, 0)
    ) +
    guides(fill = guide_legend(
      ncol      = legend_columns,
      reverse   = TRUE,
      keyheight = unit(legend_key_cm, "cm"),
      keywidth  = unit(legend_key_cm, "cm")
    ))

  out_png <- file.path(out_dir, paste0("ground_truth_stacked_bar_", tolower(rank_label), ".png"))
  out_pdf <- file.path(out_dir, paste0("ground_truth_stacked_bar_", tolower(rank_label), ".pdf"))
  ggsave(out_png, p, width = 10, height = 7, dpi = 150, bg = "white")
  ggsave(out_pdf, p, width = 10, height = 7, bg = "white")
  cat("Saved:", out_png, "\n")
  cat("Saved:", out_pdf, "\n")
}

# ── Generate species chart ────────────────────────────────────────────────────
cat("Parsing ground truth:", GROUND_TRUTH, "\n")

species_df <- parse_cami_profile(GROUND_TRUTH, "species")
if (!is.null(species_df)) {
  cat("Species rows:", nrow(species_df), "\n")
  make_stacked_bar(species_df, "taxon", "Species", TOP_N, OUT_DIR, "Ground Truth")
} else {
  cat("No species data found\n")
}

# ── Generate genus chart ──────────────────────────────────────────────────────
genus_df <- parse_cami_profile(GROUND_TRUTH, "genus")
if (!is.null(genus_df)) {
  cat("Genus rows:", nrow(genus_df), "\n")
  make_stacked_bar(genus_df, "taxon", "Genus", TOP_N, OUT_DIR, "Ground Truth")
} else {
  cat("No genus data found\n")
}

cat("Done.\n")
