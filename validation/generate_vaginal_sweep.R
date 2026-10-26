#!/usr/bin/env Rscript
# generate_vaginal_sweep.R
# Reproduces the gut/oral/skin heatmap-sweep style for the vaginal DB,
# using pre-computed scores_vaginaldb.tsv pulled from the Nectar VM.
#
# Usage:
#   Rscript validation/generate_vaginal_sweep.R [scores_tsv] [out_png]
#
# Defaults:
#   scores_tsv : /tmp/scores_vaginaldb.tsv
#   out_png    : ~/Desktop/STAMINA-BIOME_Vaginal_Sweep.png

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(gridExtra)
  library(grid)
})

args      <- commandArgs(trailingOnly = TRUE)
SCORES    <- if (length(args) >= 1) args[1] else "/tmp/scores_vaginaldb.tsv"
OUT_PNG   <- if (length(args) >= 2) args[2] else file.path(path.expand("~/Desktop"), "STAMINA-BIOME_Vaginal_Sweep.png")

# ── Load and filter ───────────────────────────────────────────────────────────
raw <- read.table(SCORES, sep = "\t", header = TRUE,
                  stringsAsFactors = FALSE, check.names = FALSE)

# Keep only the vaginal-metagenome rows, base runs (no _bracken suffix)
df <- raw %>%
  filter(dataset == "vaginal",
         !grepl("_bracken", run_id)) %>%
  mutate(
    conf     = as.numeric(confidence),
    mhg      = as.integer(mhg),
    recovery = as.numeric(recovery_pct),
    n_fp     = as.integer(false_positives),
    mae_pct  = as.numeric(MAE_pct),
    n_true   = as.integer(species_total),
    tp       = round(recovery / 100 * n_true)
  ) %>%
  mutate(
    precision = ifelse((tp + n_fp) > 0, tp / (tp + n_fp), NA_real_),
    recall    = tp / n_true,
    f1        = ifelse(!is.na(precision) & (precision + recall) > 0,
                       2 * precision * recall / (precision + recall),
                       NA_real_)
  )

n_true  <- df$n_true[1]
conf_levels <- sort(unique(df$conf))
mhg_levels  <- sort(unique(df$mhg))

cat(sprintf("Vaginal DB sweep: %d conf values × %d mhg values | %d true species\n",
            length(conf_levels), length(mhg_levels), n_true))
print(df[, c("conf","mhg","recovery","n_fp","mae_pct","precision","recall","f1")])

# ── Heatmap builder (matches sweep_kraken_params.R style) ────────────────────
BASE_COL <- "#7B1FA2"   # purple for vaginal

make_heatmap <- function(data, value_col, title,
                         fmt_fn = identity,
                         low = "white", high = BASE_COL) {
  data2 <- data %>%
    mutate(
      conf_lbl = sprintf("%.2f", conf),
      mhg_lbl  = as.character(mhg),
      val      = .data[[value_col]]
    )
  # Fix factor ordering so conf increases bottom→top (matching other sweeps)
  data2$conf_lbl <- factor(data2$conf_lbl,
                           levels = rev(sprintf("%.2f", conf_levels)))
  data2$mhg_lbl  <- factor(data2$mhg_lbl,
                            levels = as.character(mhg_levels))

  ggplot(data2, aes(x = mhg_lbl, y = conf_lbl, fill = val)) +
    geom_tile(colour = "white", linewidth = 0.8) +
    geom_text(aes(label = fmt_fn(val)), size = 4.5, fontface = "bold") +
    scale_fill_gradient(low = low, high = high,
                        na.value = "grey90", guide = "none") +
    labs(title = title, x = "Min Hit Groups", y = "Confidence") +
    theme_minimal(base_size = 11) +
    theme(
      plot.title      = element_text(size = 10, face = "bold"),
      axis.text       = element_text(size = 9),
      panel.grid      = element_blank(),
      aspect.ratio    = length(conf_levels) / length(mhg_levels)
    )
}

pA <- make_heatmap(df, "recovery", "A  Recovery (%)",
                   fmt_fn = function(x) paste0(x, "%"))

pB <- make_heatmap(df, "n_fp", "B  False Positives",
                   high = "#F44336", low = "white")

pC <- make_heatmap(df, "mae_pct", "C  Abundance MAE (%)",
                   fmt_fn = function(x) paste0(x, "%"),
                   high = "#FF9800", low = "white")

pD <- make_heatmap(df, "f1", "D  F1-score",
                   fmt_fn = function(x) ifelse(is.na(x), "—", sprintf("%.3f", x)))

# ── Assemble figure ───────────────────────────────────────────────────────────
title_grob <- textGrob(
  "STAMINA-BIOME Vaginal — stamina-biome-vaginal DB: Kraken2 Parameter Sweep",
  gp = gpar(fontsize = 13, fontface = "bold"))

sub_grob <- textGrob(
  sprintf(
    "Confidence %s–%s × Min Hit Groups %s–%s | %d true species | Bracken 1200 bp | CAMISIM vaginal mock metagenome",
    min(conf_levels), max(conf_levels),
    min(mhg_levels),  max(mhg_levels),
    n_true
  ),
  gp = gpar(fontsize = 9, col = "grey40"))

top_row <- arrangeGrob(pA, pB, ncol = 2)
bot_row <- arrangeGrob(pC, pD, ncol = 2)

fig <- arrangeGrob(
  title_grob, sub_grob, top_row, bot_row,
  heights = c(0.06, 0.04, 0.45, 0.45),
  ncol    = 1
)

ggsave(OUT_PNG, fig, width = 8, height = 9, dpi = 200, bg = "white")
cat(sprintf("\nSaved → %s\n", OUT_PNG))
