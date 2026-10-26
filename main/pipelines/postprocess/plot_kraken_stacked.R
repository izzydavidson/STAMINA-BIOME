#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop(
    paste0(
      "Usage:\n",
      "  Rscript plot_kraken_stacked.R <TAXONOMY_ROOT> <RUN_BASE> [rank=species|genus] [top_n=25]\n\n",
      "Example:\n",
      "  Rscript plot_kraken_stacked.R /home/ubuntu/data/Data/Taxonomy vaginal_testrun species 25\n"
    ),
    call. = FALSE
  )
}

tax_root <- args[1]
run_base <- args[2]
rank <- ifelse(length(args) >= 3, args[3], "species")
rank <- tolower(rank)
top_n <- ifelse(length(args) >= 4, suppressWarnings(as.integer(args[4])), 25)
if (is.na(top_n) || top_n < 1) top_n <- 25

if (!(rank %in% c("species", "genus"))) stop("rank must be 'species' or 'genus'", call. = FALSE)

MIN_PROP <- 0.0
LEGEND_NCOL <- 4

dirs <- list.dirs(tax_root, full.names = TRUE, recursive = FALSE)
dirs <- dirs[grepl(paste0("^", run_base, "_[0-9.]+param$"), basename(dirs))]

if (length(dirs) == 0) {
  stop(paste("No parameter directories found under", tax_root, "for base", run_base), call. = FALSE)
}

get_param <- function(folder_name) {
  m <- str_match(folder_name, paste0("^", run_base, "_([0-9.]+)param$"))
  ifelse(is.na(m[, 2]), NA, m[, 2])
}

read_long_any <- function(path, fallback_sample_name) {
  df <- suppressMessages(read_csv(path, show_col_types = FALSE))
  cn <- colnames(df)
  
  # Detect "tidy/long" format
  sample_col <- cn[tolower(cn) %in% c("sampleid", "sample_id", "sample", "id")]
  tax_col <- cn[tolower(cn) %in% c("taxon", "name", "taxa", "species", "genus")]
  ab_col  <- cn[tolower(cn) %in% c("abundance", "fraction", "prop", "proportion", "relative_abundance", "rel_abundance", "count", "reads")]
  
  if (length(tax_col) > 0 && length(ab_col) > 0) {
    tax_col <- tax_col[1]
    ab_col <- ab_col[1]
    has_sample <- length(sample_col) > 0
    if (has_sample) sample_col <- sample_col[1]
    
    out <- df %>%
      transmute(
        SampleID = if (has_sample) as.character(.data[[sample_col]]) else fallback_sample_name,
        Taxon = as.character(.data[[tax_col]]),
        Abundance = suppressWarnings(as.numeric(.data[[ab_col]]))
      ) %>%
      filter(!is.na(SampleID), !is.na(Taxon), !is.na(Abundance))
    return(out)
  }
  
  # Otherwise assume "wide" format
  first_col <- cn[1]
  first_vals <- df[[first_col]]
  treat_first_as_sample <- is.character(first_vals) || is.factor(first_vals)
  
  if (treat_first_as_sample) {
    out <- df %>%
      mutate(SampleID = as.character(.data[[first_col]])) %>%
      select(-all_of(first_col)) %>%
      mutate(across(-SampleID, ~ suppressWarnings(as.numeric(.x)))) %>%
      pivot_longer(cols = -SampleID, names_to = "Taxon", values_to = "Abundance") %>%
      filter(!is.na(SampleID), !is.na(Taxon), !is.na(Abundance))
    return(out)
  } else {
    out <- df %>%
      mutate(across(everything(), ~ suppressWarnings(as.numeric(.x)))) %>%
      pivot_longer(cols = everything(), names_to = "Taxon", values_to = "Abundance") %>%
      mutate(SampleID = fallback_sample_name) %>%
      filter(!is.na(Taxon), !is.na(Abundance))
    return(out)
  }
}

coerce_to_proportions <- function(long_df) {
  sums <- long_df %>%
    group_by(SampleID) %>%
    summarise(s = sum(Abundance, na.rm = TRUE), .groups = "drop")
  
  # If it looks like counts, normalize
  if (any(sums$s > 1.5, na.rm = TRUE)) {
    long_df <- long_df %>%
      group_by(SampleID) %>%
      mutate(Abundance = Abundance / sum(Abundance, na.rm = TRUE)) %>%
      ungroup()
  }
  long_df
}

plot_one_run <- function(run_dir) {
  run_name <- basename(run_dir)
  param <- get_param(run_name)
  if (is.na(param)) {
    message("[WARN] Could not parse param for: ", run_name)
    return(invisible(FALSE))
  }
  
  # Prefer tidy files that your pipeline already writes
  f_tidy <- file.path(run_dir, paste0("kraken_", rank, "_tidy.csv"))
  f_wide <- file.path(run_dir, paste0("kraken_", rank, "_wide.csv"))
  
  # Fall back to result tables if tidy/wide not present
  f_rank_table <- file.path(run_dir, paste0(run_name, "_", rank, "_result_table.csv"))
  f_legacy_table <- file.path(run_dir, paste0(run_name, "_result_table.csv"))
  
  path <- NA
  if (file.exists(f_tidy)) {
    path <- f_tidy
  } else if (file.exists(f_wide)) {
    path <- f_wide
  } else if (file.exists(f_rank_table)) {
    path <- f_rank_table
  } else if (file.exists(f_legacy_table)) {
    path <- f_legacy_table
  }
  
  if (is.na(path)) {
    message("[WARN] No input file found for ", run_name, " (rank=", rank, ")")
    return(invisible(FALSE))
  }
  
  long <- read_long_any(path, fallback_sample_name = run_name) %>%
    filter(!is.na(Abundance), Abundance > 0)
  
  if (nrow(long) == 0) {
    message("[WARN] Empty data after parsing for ", run_name)
    return(invisible(FALSE))
  }
  
  long <- coerce_to_proportions(long)
  
  if (MIN_PROP > 0) {
    long <- long %>% filter(Abundance >= MIN_PROP)
  }
  
  # Top taxa PER RUN
  top_taxa <- long %>%
    group_by(Taxon) %>%
    summarise(mean_ab = mean(Abundance, na.rm = TRUE), .groups = "drop") %>%
    arrange(desc(mean_ab)) %>%
    slice_head(n = top_n) %>%
    pull(Taxon)
  
  df_plot <- long %>%
    mutate(Taxon_plot = ifelse(Taxon %in% top_taxa, Taxon, "Other")) %>%
    group_by(SampleID, Taxon_plot) %>%
    summarise(Abundance = sum(Abundance, na.rm = TRUE), .groups = "drop") %>%
    group_by(SampleID) %>%
    mutate(Abundance = Abundance / sum(Abundance, na.rm = TRUE)) %>%
    ungroup()
  
  # Ensure "Other" is last in legend
  tax_levels <- unique(df_plot$Taxon_plot)
  if ("Other" %in% tax_levels) tax_levels <- c(setdiff(tax_levels, "Other"), "Other")
  df_plot$Taxon_plot <- factor(df_plot$Taxon_plot, levels = tax_levels)
  
  # Save debug long table per-run (optional but handy)
  out_long <- file.path(run_dir, paste0(run_name, "_", rank, "_stacked_top", top_n, "_long.csv"))
  write_csv(df_plot, out_long)
  
  p <- ggplot(df_plot, aes(x = SampleID, y = Abundance, fill = Taxon_plot)) +
    geom_col(width = 0.85) +
    labs(
      title = paste0(run_name, " (", rank, ")"),
      subtitle = paste0("param=", param, " | top ", top_n, " + Other"),
      x = "Sample",
      y = "Proportion",
      fill = paste0(rank, " (top ", top_n, ")")
    ) +
    theme(
      axis.text.x = element_text(angle = 60, hjust = 1, size = 7),
      legend.position = "bottom",
      legend.text = element_text(size = 8),
      legend.title = element_text(size = 9)
    ) +
    guides(fill = guide_legend(ncol = LEGEND_NCOL))
  
  out_png <- file.path(run_dir, paste0(run_name, "_", rank, "_stacked_top", top_n, ".png"))
  out_pdf <- file.path(run_dir, paste0(run_name, "_", rank, "_stacked_top", top_n, ".pdf"))
  
  ggsave(out_png, p, width = 14, height = 8, dpi = 300, bg = "white")
  ggsave(out_pdf, p, width = 14, height = 8, bg = "white")
  
  message("[OK] ", run_name, " -> ", basename(out_png))
  invisible(TRUE)
}

ok <- 0
for (d in dirs) {
  if (isTRUE(plot_one_run(d))) ok <- ok + 1
}

cat("Done.\n")
cat("Found param dirs:", length(dirs), "\n")
cat("Plotted:", ok, "\n")

