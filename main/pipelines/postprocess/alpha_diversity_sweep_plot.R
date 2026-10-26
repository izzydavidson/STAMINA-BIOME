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
      "  Rscript plot_alpha_diversity_sweep.R <DIVERSITY_ROOT> <RUN_BASE> ",
      "[metrics=shannon,observed_features,pielou_e] [out_name=alpha]\n\n",
      "Expected directory layout:\n",
      "  <DIVERSITY_ROOT>/<RUN_BASE>_<num>param/\n",
      "Inside each param folder, any of these are accepted:\n",
      "  diversity/shannon_export/alpha-diversity.tsv\n",
      "  diversity/observed_features_export/alpha-diversity.tsv\n",
      "  diversity/pielou_e_export/alpha-diversity.tsv\n",
      "Or a single table:\n",
      "  alpha_diversity.csv / alpha_diversity.tsv (wide or long)\n"
    ),
    call. = FALSE
  )
}

div_root <- args[1]
run_base <- args[2]
metrics_arg <- ifelse(length(args) >= 3, args[3], "shannon,observed_features,pielou_e")
out_name <- ifelse(length(args) >= 4, args[4], "alpha")

metrics_wanted <- tolower(trimws(unlist(strsplit(metrics_arg, ","))))
metrics_wanted <- metrics_wanted[metrics_wanted != ""]

if (!dir.exists(div_root)) stop(paste("DIVERSITY_ROOT not found:", div_root), call. = FALSE)

dirs <- list.dirs(div_root, full.names = TRUE, recursive = FALSE)
dirs <- dirs[grepl(paste0("^", run_base, "_[0-9.]+param$"), basename(dirs))]

if (length(dirs) == 0) {
  stop(paste("No parameter directories found under", div_root, "for base", run_base), call. = FALSE)
}

get_param <- function(folder_name) {
  m <- str_match(folder_name, paste0("^", run_base, "_([0-9.]+)param$"))
  ifelse(is.na(m[, 2]), NA, m[, 2])
}

read_any_table <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("tsv", "txt")) {
    return(suppressMessages(read_tsv(path, show_col_types = FALSE)))
  }
  suppressMessages(read_csv(path, show_col_types = FALSE))
}

detect_sample_col <- function(cn) {
  cn_low <- tolower(cn)
  hit <- cn[cn_low %in% c("sampleid", "sample_id", "sample", "id", "#sampleid", "#sample_id")]
  if (length(hit) > 0) return(hit[1])
  return(NA_character_)
}

# Try QIIME2-exported alpha-diversity.tsv for a single metric
read_qiime2_alpha_export <- function(param_dir, metric_name, param_val) {
  candidates <- c(
    file.path("diversity", paste0(metric_name, "_export"), "alpha-diversity.tsv"),
    file.path("diversity", metric_name, "alpha-diversity.tsv")
  )
  paths <- file.path(param_dir, candidates)
  paths <- paths[file.exists(paths)]
  if (length(paths) == 0) return(NULL)
  
  df <- read_any_table(paths[1])
  cn <- colnames(df)
  sample_col <- detect_sample_col(cn)
  if (is.na(sample_col)) sample_col <- cn[1]
  
  # QIIME2 alpha-diversity.tsv is typically: SampleID <tab> alpha_diversity
  value_col <- setdiff(cn, sample_col)
  if (length(value_col) == 0) return(NULL)
  value_col <- value_col[1]
  
  out <- df %>%
    transmute(
      param = as.character(param_val),
      param_num = suppressWarnings(as.numeric(param_val)),
      SampleID = as.character(.data[[sample_col]]),
      metric = tolower(metric_name),
      value = suppressWarnings(as.numeric(.data[[value_col]]))
    ) %>%
    filter(!is.na(SampleID), !is.na(value))
  
  out
}

# Fallback: user-provided alpha_diversity.(csv|tsv) wide or long inside param folder
read_alpha_any_fallback <- function(param_dir, param_val) {
  candidates <- c(
    "alpha_diversity_long.csv", "alpha_diversity_long.tsv",
    "alpha_diversity.csv", "alpha_diversity.tsv"
  )
  paths <- file.path(param_dir, candidates)
  paths <- paths[file.exists(paths)]
  if (length(paths) == 0) return(NULL)
  
  # Prefer long if present
  paths <- paths[order(grepl("long", basename(paths), ignore.case = TRUE), decreasing = TRUE)]
  df <- read_any_table(paths[1])
  
  cn <- colnames(df)
  cn_low <- tolower(cn)
  
  sample_col <- detect_sample_col(cn)
  metric_col <- cn[cn_low %in% c("metric", "measure", "index")]
  value_col  <- cn[cn_low %in% c("value", "val", "diversity", "alpha", "score")]
  
  # Long
  if (!is.na(sample_col) && length(metric_col) > 0 && length(value_col) > 0) {
    metric_col <- metric_col[1]
    value_col <- value_col[1]
    return(
      df %>%
        transmute(
          param = as.character(param_val),
          param_num = suppressWarnings(as.numeric(param_val)),
          SampleID = as.character(.data[[sample_col]]),
          metric = tolower(as.character(.data[[metric_col]])),
          value = suppressWarnings(as.numeric(.data[[value_col]]))
        ) %>%
        filter(!is.na(SampleID), !is.na(metric), !is.na(value))
    )
  }
  
  # Wide: sample + columns are metrics
  if (is.na(sample_col)) sample_col <- cn[1]
  
  df %>%
    mutate(SampleID = as.character(.data[[sample_col]])) %>%
    select(-all_of(sample_col)) %>%
    pivot_longer(cols = everything(), names_to = "metric", values_to = "value") %>%
    mutate(
      param = as.character(param_val),
      param_num = suppressWarnings(as.numeric(param_val)),
      metric = tolower(as.character(metric)),
      value = suppressWarnings(as.numeric(value))
    ) %>%
    filter(!is.na(SampleID), metric != "", !is.na(value))
}

all_long <- list()

for (d in dirs) {
  run_name <- basename(d)
  param <- get_param(run_name)
  if (is.na(param)) next
  
  # Prefer explicit QIIME2 export per metric
  got_any <- FALSE
  for (m in metrics_wanted) {
    dat_m <- read_qiime2_alpha_export(d, m, param)
    if (!is.null(dat_m) && nrow(dat_m) > 0) {
      all_long[[length(all_long) + 1]] <- dat_m
      got_any <- TRUE
    }
  }
  
  # Fallback: any alpha_diversity table inside param folder
  if (!got_any) {
    dat_fb <- read_alpha_any_fallback(d, param)
    if (!is.null(dat_fb) && nrow(dat_fb) > 0) {
      all_long[[length(all_long) + 1]] <- dat_fb
      got_any <- TRUE
    }
  }
  
  if (!got_any) {
    message("[WARN] No alpha diversity data found in ", run_name)
  }
}

if (length(all_long) == 0) {
  stop("No alpha diversity data found in any param directory.", call. = FALSE)
}

df <- bind_rows(all_long)

out_tidy <- file.path(div_root, paste0(run_base, "_", out_name, "_diversity_long.csv"))
write_csv(df, out_tidy)

available <- sort(unique(df$metric))
missing <- setdiff(metrics_wanted, available)
if (length(missing) > 0) {
  message("[WARN] Missing requested metrics: ", paste(missing, collapse = ", "))
  message("[INFO] Available metrics: ", paste(available, collapse = ", "))
}

metrics_to_plot <- intersect(metrics_wanted, available)
if (length(metrics_to_plot) == 0) {
  stop("None of the requested metrics exist in the data.", call. = FALSE)
}

# consistent param ordering
param_levels <- df %>%
  distinct(param, param_num) %>%
  arrange(param_num, param) %>%
  pull(param)

df <- df %>% mutate(param = factor(as.character(param), levels = param_levels))

plot_one_metric <- function(metric_name) {
  df_m <- df %>% filter(metric == metric_name)
  
  # Boxplot + jitter
  p1 <- ggplot(df_m, aes(x = param, y = value)) +
    geom_boxplot(outlier.shape = NA) +
    geom_jitter(width = 0.15, height = 0, alpha = 0.7, size = 1) +
    labs(
      title = paste0("Alpha diversity across sweep (", run_base, ")"),
      subtitle = paste0("metric=", metric_name),
      x = "Sweep parameter",
      y = "Alpha diversity"
    ) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 6))
  
  out_png1 <- file.path(div_root, paste0(run_base, "_", out_name, "_", metric_name, "_sweep_box.png"))
  out_pdf1 <- file.path(div_root, paste0(run_base, "_", out_name, "_", metric_name, "_sweep_box.pdf"))
  ggsave(out_png1, p1, width = 12, height = 6, dpi = 300, bg = "white")
  ggsave(out_pdf1, p1, width = 12, height = 6, bg = "white")
  
  # Mean +/- sd vs param
  summ <- df_m %>%
    group_by(param, param_num) %>%
    summarise(
      mean = mean(value, na.rm = TRUE),
      sd = sd(value, na.rm = TRUE),
      n = dplyr::n(),
      .groups = "drop"
    )
  
  p2 <- ggplot(summ, aes(x = param, y = mean, group = 1)) +
    geom_point(size = 2) +
    geom_line() +
    geom_errorbar(aes(ymin = mean - sd, ymax = mean + sd), width = 0.2) +
    labs(
      title = paste0("Mean alpha diversity vs sweep parameter (", run_base, ")"),
      subtitle = paste0("metric=", metric_name, " | error bars = ±sd"),
      x = "Sweep parameter",
      y = "Mean alpha diversity"
    ) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 6))
  
  out_png2 <- file.path(div_root, paste0(run_base, "_", out_name, "_", metric_name, "_sweep_mean.png"))
  out_pdf2 <- file.path(div_root, paste0(run_base, "_", out_name, "_", metric_name, "_sweep_mean.pdf"))
  ggsave(out_png2, p2, width = 12, height = 5, dpi = 300, bg = "white")
  ggsave(out_pdf2, p2, width = 12, height = 5, bg = "white")
  
  list(out_png1, out_pdf1, out_png2, out_pdf2)
}

all_outputs <- c(out_tidy)

for (m in metrics_to_plot) {
  outs <- plot_one_metric(m)
  all_outputs <- c(all_outputs, outs)
}

cat("Saved:\n")
for (p in all_outputs) cat("  ", p, "\n")
