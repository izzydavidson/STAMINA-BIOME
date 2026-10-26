#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(ggplot2)
  library(tidyr)
})

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop("Usage: Rscript plot_valencia_cst_sweep.R <VALENCIA_RESULTS_DIR> <RUN_BASE>", call. = FALSE)
}

val_dir <- args[1]
run_base <- args[2]

prop_csv <- file.path(val_dir, paste0(run_base, "_valencia_cst_proportions_by_param.csv"))
if (!file.exists(prop_csv)) {
  stop(paste("Proportions CSV not found:", prop_csv), call. = FALSE)
}

df <- read_csv(prop_csv, show_col_types = FALSE) %>%
  mutate(
    param = as.character(param),
    param_num = suppressWarnings(as.numeric(param)),
    CST = as.character(CST),
    proportion = as.numeric(proportion)
  ) %>%
  filter(!is.na(proportion))

n_params <- length(unique(df$param))
if (n_params <= 1) {
  cat("Only", n_params, "param value found; not enough to plot a sweep.\n")
  quit(save = "no", status = 0)
}

# Order params numerically
param_levels <- df %>%
  distinct(param, param_num) %>%
  arrange(param_num, param) %>%
  pull(param)

df <- df %>%
  mutate(param = factor(param, levels = param_levels))

# If there are many CSTs, group rare ones into "Other" to keep plot readable
max_csts <- 8

cst_rank <- df %>%
  group_by(CST) %>%
  summarise(mean_prop = mean(proportion, na.rm = TRUE), .groups = "drop") %>%
  arrange(desc(mean_prop))

keep_csts <- head(cst_rank$CST, max_csts)

df_plot <- df %>%
  mutate(CST_plot = ifelse(CST %in% keep_csts, CST, "Other")) %>%
  group_by(param, CST_plot) %>%
  summarise(proportion = sum(proportion, na.rm = TRUE), .groups = "drop") %>%
  group_by(param) %>%
  mutate(proportion = proportion / sum(proportion, na.rm = TRUE)) %>%
  ungroup()

# Keep "Other" last in legend if present
cst_levels <- unique(df_plot$CST_plot)
if ("Other" %in% cst_levels) {
  cst_levels <- c(setdiff(cst_levels, "Other"), "Other")
}
df_plot$CST_plot <- factor(df_plot$CST_plot, levels = cst_levels)

p1 <- ggplot(df_plot, aes(x = param, y = proportion, fill = CST_plot)) +
  geom_col(width = 0.75) +
  labs(
    title = paste0("VALENCIA CST composition across sweep (", run_base, ")"),
    x = "Sweep parameter (e.g. Kraken confidence)",
    y = "Proportion",
    fill = "CST"
  ) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1, size = 5),
    legend.position = "bottom"
  )

out_png1 <- file.path(val_dir, paste0(run_base, "_valencia_cst_sweep_stacked.png"))
out_pdf1 <- file.path(val_dir, paste0(run_base, "_valencia_cst_sweep_stacked.pdf"))
ggsave(out_png1, p1, width = 12, height = 6, dpi = 300)
ggsave(out_pdf1, p1, width = 12, height = 6)

# Dominant CST per param (simple summary plot)
dom <- df %>%
  group_by(param, param_num, CST) %>%
  summarise(proportion = sum(proportion, na.rm = TRUE), .groups = "drop") %>%
  group_by(param, param_num) %>%
  slice_max(order_by = proportion, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  mutate(param = factor(as.character(param), levels = param_levels))

p2 <- ggplot(dom, aes(x = param, y = proportion, group = 1)) +
  geom_point(size = 2) +
  geom_line() +
  labs(
    title = paste0("Dominant CST vs sweep parameter (", run_base, ")"),
    x = "Sweep parameter",
    y = "Dominant CST proportion"
  ) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1, size = 5)
  )

out_png2 <- file.path(val_dir, paste0(run_base, "_valencia_cst_sweep_dominant.png"))
out_pdf2 <- file.path(val_dir, paste0(run_base, "_valencia_cst_sweep_dominant.pdf"))
ggsave(out_png2, p2, width = 12, height = 5, dpi = 300)
ggsave(out_pdf2, p2, width = 12, height = 5)

cat("Saved plots:\n")
cat(" ", out_png1, "\n")
cat(" ", out_pdf1, "\n")
cat(" ", out_png2, "\n")
cat(" ", out_pdf2, "\n")

