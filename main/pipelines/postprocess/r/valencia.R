#!/usr/bin/env Rscript

# =============================================================================
# STAMINA-BIOME R Postprocess: VALENCIA Results Processing
# Generates additional VALENCIA visualizations and summaries
# =============================================================================

suppressPackageStartupMessages({
  if (requireNamespace("jsonlite", quietly = TRUE)) {
    library(jsonlite)
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
  stop("Usage: valencia.R --outputs_json <path> --out_dir <dir> [--params_json <json>] [--module <name>]")
}

# Load outputs.json
outputs <- fromJSON(outputs_json)
params <- tryCatch(fromJSON(params_json), error = function(e) list())

# Shared sample ordering: samples in the order entered in the GUI/CLI sample sheet
local({
  f <- sub("^--file=", "", grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1])
  d <- if (!is.na(f) && nzchar(f)) dirname(normalizePath(f)) else getwd()
  for (p in c(file.path(d, "sample_order.R"),
              file.path(d, "..", "..", "..", "..", "main", "pipelines", "postprocess", "r", "sample_order.R"))) {
    if (file.exists(p)) { sys.source(p, envir = globalenv()); break }
  }
})
if (!exists("sample_levels", mode = "function")) {
  sample_levels <- function(ids, params = list()) sort(unique(as.character(ids)))
  group_levels <- function(sample_ids, groups, sample_lv) {
    unique(as.character(groups)[order(match(as.character(sample_ids), sample_lv))])
  }
  order_rows_by_sample <- function(df, col = "sample_id", params = list()) df
}

cat("[valencia] Module:", module_name, "\n")
cat("[valencia] Output dir:", out_dir, "\n")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Find VALENCIA outputs (check multiple possible key names)
valencia_info <- outputs$valencia
if (is.null(valencia_info)) {
  valencia_info <- outputs$valencia_results
}
if (is.null(valencia_info)) {
  cat("[valencia] No VALENCIA outputs found in outputs.json\n")
  quit(save = "no", status = 0)
}

# Try to find VALENCIA assignments CSV
valencia_csv <- NULL

# Handle case where valencia_info is a string (file path or directory)
if (is.character(valencia_info)) {
  if (file.exists(valencia_info)) {
    if (dir.exists(valencia_info)) {
      # It's a directory - look for CSV files
      valencia_dir <- valencia_info
      candidates <- c(
        file.path(valencia_dir, "output.csv"),
        file.path(valencia_dir, "valencia_assignments.csv"),
        list.files(valencia_dir, pattern = "_valencia_assignments\\.csv$", full.names = TRUE),
        list.files(valencia_dir, pattern = "output\\.csv$", full.names = TRUE)
      )
      for (f in candidates) {
        if (file.exists(f)) {
          valencia_csv <- f
          break
        }
      }
    } else {
      # It's a file
      valencia_csv <- valencia_info
    }
  }
} else if (is.list(valencia_info)) {
  # Handle case where valencia_info is a list/dict
  if (!is.null(valencia_info$output_csv) && file.exists(valencia_info$output_csv)) {
    valencia_csv <- valencia_info$output_csv
  } else if (!is.null(valencia_info$assignments_csv) && file.exists(valencia_info$assignments_csv)) {
    valencia_csv <- valencia_info$assignments_csv
  } else if (!is.null(valencia_info$dir)) {
    # Look for any VALENCIA output CSV in the directory
    valencia_dir <- valencia_info$dir
    candidates <- c(
      file.path(valencia_dir, "output.csv"),
      file.path(valencia_dir, "valencia_assignments.csv"),
      list.files(valencia_dir, pattern = "_valencia_assignments\\.csv$", full.names = TRUE),
      list.files(valencia_dir, pattern = "output\\.csv$", full.names = TRUE)
    )
    for (f in candidates) {
      if (file.exists(f)) {
        valencia_csv <- f
        break
      }
    }
  }
}

# Fallback: check final/valencia directory
if (is.null(valencia_csv) || !file.exists(valencia_csv)) {
  # Get module dir from outputs.json path
  outputs_dir <- dirname(outputs_json)
  final_valencia_dir <- file.path(outputs_dir, "final", "valencia")

  if (dir.exists(final_valencia_dir)) {
    candidates <- c(
      file.path(final_valencia_dir, "output.csv"),
      file.path(final_valencia_dir, "valencia_assignments.csv"),
      list.files(final_valencia_dir, pattern = "_valencia_assignments\\.csv$", full.names = TRUE),
      list.files(final_valencia_dir, pattern = "output\\.csv$", full.names = TRUE),
      list.files(final_valencia_dir, pattern = "\\.csv$", full.names = TRUE)
    )
    for (f in candidates) {
      if (file.exists(f)) {
        valencia_csv <- f
        break
      }
    }
  }
}

if (is.null(valencia_csv) || !file.exists(valencia_csv)) {
  cat("[valencia] No VALENCIA assignments CSV found\n")
  quit(save = "no", status = 0)
}

cat("[valencia] Using VALENCIA output:", valencia_csv, "\n")

# Read VALENCIA results
valencia_data <- tryCatch({
  read.csv(valencia_csv, stringsAsFactors = FALSE)
}, error = function(e) {
  cat("[valencia] Failed to read VALENCIA CSV:", e$message, "\n")
  return(NULL)
})

if (is.null(valencia_data) || nrow(valencia_data) == 0) {
  cat("[valencia] VALENCIA data is empty\n")
  quit(save = "no", status = 0)
}

cat("[valencia] Loaded", nrow(valencia_data), "samples from VALENCIA results\n")

# Identify key columns
sample_col <- intersect(c("sampleID", "sample_id", "SampleID"), colnames(valencia_data))[1]
cst_col <- intersect(c("CST", "cst"), colnames(valencia_data))[1]
subcst_col <- intersect(c("subCST", "sub_CST", "SubCST"), colnames(valencia_data))[1]
score_col <- intersect(c("score", "Score"), colnames(valencia_data))[1]

# Find similarity columns
sim_cols <- grep("_sim$", colnames(valencia_data), value = TRUE)

if (is.na(sample_col)) {
  sample_col <- colnames(valencia_data)[1]
  cat("[valencia] Using first column as sample ID:", sample_col, "\n")
}

# Samples in the order they were entered in the GUI/CLI
valencia_data <- order_rows_by_sample(valencia_data, sample_col, params)

# ---------------------------------------------------------------------------
# VALENCIA plots: samples shown by the names entered in the GUI/CLI sample
# sheet, in the order entered; CSTs in their standard order and colours.
# ---------------------------------------------------------------------------
valencia_ids <- as.character(valencia_data[[sample_col]])
sample_display <- local({
  out <- valencia_ids
  sheet <- if (exists("read_sample_order_sheet", mode = "function")) read_sample_order_sheet(params) else NULL
  if (!is.null(sheet)) {
    nm <- setNames(trimws(sheet$sample_name), trimws(sheet$barcode))
    bc <- sub("^.*_(barcode[0-9]+)$", "\\1", valencia_ids)
    hit <- unname(nm[bc])
    use <- !is.na(hit) & nzchar(hit)
    out[use] <- hit[use]
  }
  make.unique(out, sep = " ")
})

SUBCST_ORDER <- c("I-A", "I-B", "II", "III-A", "III-B", "IV-A", "IV-B",
                  "IV-C0", "IV-C1", "IV-C2", "IV-C3", "IV-C4", "V")
SUBCST_COLORS <- c("I-A" = "#08519C", "I-B" = "#6BAED6", "II" = "#FD8D3C",
                   "III-A" = "#238B45", "III-B" = "#74C476", "IV-A" = "#CB181D",
                   "IV-B" = "#6A51A3", "IV-C0" = "#8C510A", "IV-C1" = "#BF812D",
                   "IV-C2" = "#DFC27D", "IV-C3" = "#C51B7D", "IV-C4" = "#F1B6DA",
                   "V" = "#E6AB02")
CST_ORDER <- c("I", "II", "III", "IV-A", "IV-B", "IV-C", "V")
CST_COLORS <- c("I" = "#2171B5", "II" = "#FD8D3C", "III" = "#41AB5D", "IV-A" = "#CB181D",
                "IV-B" = "#6A51A3", "IV-C" = "#A6611A", "V" = "#E6AB02")

# Labels in a canonical order first, anything unexpected after
canonical_levels <- function(values, canon) {
  v <- unique(as.character(values[!is.na(values) & nzchar(values)]))
  c(canon[canon %in% v], sort(setdiff(v, canon)))
}
pick_colors <- function(labels, palette) {
  unname(ifelse(labels %in% names(palette), palette[labels], "gray60"))
}
# Left margin (in text lines) wide enough for the longest label
label_margin <- function(labels, cex = 0.9) {
  max(4, 1 + 0.55 * cex * max(nchar(as.character(labels)), 1))
}

n_val <- nrow(valencia_data)
subcst_vals <- if (!is.na(subcst_col)) as.character(valencia_data[[subcst_col]]) else rep(NA_character_, n_val)
cst_vals <- if (!is.na(cst_col)) as.character(valencia_data[[cst_col]]) else rep(NA_character_, n_val)
score_vals <- if (!is.na(score_col)) suppressWarnings(as.numeric(valencia_data[[score_col]])) else rep(NA_real_, n_val)

# 1. CST by sample: one bar per sample (VALENCIA score), coloured by sub-CST
if (!is.na(subcst_col) && !is.na(score_col)) {
  out_png <- file.path(out_dir, "cst_by_sample.png")
  left <- label_margin(sample_display)
  png(out_png, width = 1500, height = max(600, 260 + n_val * 70), res = 150, bg = "white")
  par(mar = c(4.5, left, 3.5, 7), xpd = FALSE)
  # barplot(horiz) draws the first bar at the bottom: reverse so input order reads top-down
  ord <- rev(seq_len(n_val))
  bar_cols <- pick_colors(subcst_vals[ord], SUBCST_COLORS)
  bp <- barplot(score_vals[ord], horiz = TRUE, names.arg = sample_display[ord],
                col = bar_cols, border = NA, las = 1, xlim = c(0, 1), cex.names = 0.9,
                xlab = "VALENCIA score (similarity to the assigned sub-CST)",
                main = "VALENCIA community state type by sample")
  abline(v = c(0.25, 0.5, 0.75), col = "gray88", lty = 3)
  par(xpd = TRUE)
  lab <- ifelse(is.na(score_vals[ord]), subcst_vals[ord],
                paste0(subcst_vals[ord], "  (", sprintf("%.2f", score_vals[ord]), ")"))
  text(pmin(score_vals[ord], 1) + 0.01, bp, labels = lab, pos = 4, cex = 0.8, offset = 0.2)
  dev.off()
  cat("[valencia] Generated CST-by-sample chart:", out_png, "\n")
}

# 2/3. Number of samples in each CST / sub-CST (standard order, labels upright)
count_chart <- function(values, canon, palette, out_png, title, xlab) {
  found <- canonical_levels(values, canon)
  if (length(found) == 0) return(invisible(FALSE))
  # Every standard type is shown (empty ones at 0) so the result reads in context
  lv <- c(canon, setdiff(found, canon))
  counts <- as.integer(table(factor(values, levels = lv)))
  png(out_png, width = max(1000, 250 + length(lv) * 105), height = 750, res = 150, bg = "white")
  par(mar = c(4.5, 4.5, 3.5, 1))
  bp <- barplot(counts, names.arg = lv, col = pick_colors(lv, palette), border = NA, las = 1,
                ylim = c(0, max(counts) * 1.2), yaxt = "n", main = title,
                xlab = xlab, ylab = "Number of samples")
  axis(2, at = unique(round(pretty(c(0, max(counts))))), las = 1)
  text(bp[counts > 0], counts[counts > 0], labels = counts[counts > 0], pos = 3, cex = 0.9)
  dev.off()
  invisible(TRUE)
}
if (!is.na(cst_col)) {
  out_png <- file.path(out_dir, "cst_distribution.png")
  if (count_chart(cst_vals, CST_ORDER, CST_COLORS, out_png, "Samples per CST", "CST"))
    cat("[valencia] Generated CST distribution chart:", out_png, "\n")
}
if (!is.na(subcst_col)) {
  out_png <- file.path(out_dir, "subcst_distribution.png")
  if (count_chart(subcst_vals, SUBCST_ORDER, SUBCST_COLORS, out_png, "Samples per sub-CST", "Sub-CST"))
    cat("[valencia] Generated SubCST distribution chart:", out_png, "\n")
}

# 4. Similarity of every sample to every sub-CST (values printed in the cells)
if (length(sim_cols) > 0 && n_val > 0) {
  sim_mat <- as.matrix(valencia_data[, sim_cols, drop = FALSE])
  storage.mode(sim_mat) <- "numeric"
  colnames(sim_mat) <- gsub(".", "-", sub("_sim$", "", colnames(sim_mat)), fixed = TRUE)
  sim_mat <- sim_mat[, canonical_levels(colnames(sim_mat), SUBCST_ORDER), drop = FALSE]
  rownames(sim_mat) <- sample_display
  # image() draws row 1 at the bottom: reverse so input order reads top-down
  sim_plot <- sim_mat[rev(seq_len(n_val)), , drop = FALSE]
  n_cols <- ncol(sim_plot)

  out_png <- file.path(out_dir, "similarity_heatmap.png")
  left <- label_margin(sample_display)
  png(out_png, width = 500 + left * 30 + n_cols * 95, height = max(650, 330 + n_val * 60),
      res = 150, bg = "white")
  layout(matrix(c(1, 2), nrow = 1), widths = c(8, 1))
  par(mar = c(5, left, 4, 1))
  heat_cols <- colorRampPalette(c("#FFFFFF", "#C6DBEF", "#4292C6", "#08306B"))(100)
  image(seq_len(n_cols), seq_len(n_val), t(sim_plot), col = heat_cols, zlim = c(0, 1),
        xlab = "Sub-CST", ylab = "", axes = FALSE,
        main = "VALENCIA similarity to each sub-CST")
  axis(1, at = seq_len(n_cols), labels = colnames(sim_plot), las = 1, cex.axis = 0.75, tick = FALSE)
  axis(2, at = seq_len(n_val), labels = rownames(sim_plot), las = 1, cex.axis = 0.9, tick = FALSE)
  abline(v = seq_len(n_cols + 1) - 0.5, h = seq_len(n_val + 1) - 0.5, col = "white", lwd = 1)
  if (n_cols * n_val <= 600) {
    cells <- expand.grid(x = seq_len(n_cols), y = seq_len(n_val))
    v <- sim_plot[cbind(cells$y, cells$x)]
    text(cells$x, cells$y, labels = sprintf("%.2f", v), cex = 0.6,
         col = ifelse(v > 0.55, "white", "gray20"))
  }
  # Colour key
  par(mar = c(5, 0.5, 4, 3.5))
  image(1, seq(0, 1, length.out = 100), t(matrix(seq_len(100))), col = heat_cols,
        axes = FALSE, xlab = "", ylab = "")
  axis(4, at = c(0, 0.25, 0.5, 0.75, 1), las = 1, cex.axis = 0.75)
  mtext("Similarity", side = 4, line = 2.4, cex = 0.75)
  dev.off()
  cat("[valencia] Generated similarity heatmap:", out_png, "\n")
}

# 5. Score histogram: only informative with enough samples (the CST-by-sample
#    chart shows each sample's score)
if (!is.na(score_col)) {
  scores <- score_vals[!is.na(score_vals)]
  if (length(scores) >= 10) {
    out_png <- file.path(out_dir, "score_distribution.png")
    png(out_png, width = 1000, height = 750, res = 150, bg = "white")
    par(mar = c(4.5, 4.5, 3.5, 1))
    hist(scores, breaks = seq(0, 1, by = 0.05), col = "#4292C6", border = "white",
         xlab = "VALENCIA score", ylab = "Number of samples", las = 1,
         main = "VALENCIA score distribution", xlim = c(0, 1))
    abline(v = mean(scores), col = "#CB181D", lwd = 2, lty = 2)
    legend("topleft", legend = paste("Mean:", round(mean(scores), 3)), col = "#CB181D",
           lty = 2, lwd = 2, bty = "n", cex = 0.85)
    dev.off()
    cat("[valencia] Generated score distribution:", out_png, "\n")
  } else {
    cat("[valencia] Score distribution skipped (", length(scores),
        " samples; each score is on the CST-by-sample chart)\n", sep = "")
  }
}

# Write summary CSV
summary_df <- data.frame(
  sample_id = valencia_ids,
  sample_name = sample_display,
  stringsAsFactors = FALSE
)

if (!is.na(cst_col)) summary_df$CST <- valencia_data[[cst_col]]
if (!is.na(subcst_col)) summary_df$SubCST <- valencia_data[[subcst_col]]
if (!is.na(score_col)) summary_df$score <- valencia_data[[score_col]]

out_csv <- file.path(out_dir, "valencia_summary.csv")
write.csv(summary_df, out_csv, row.names = FALSE)
cat("[valencia] Wrote summary CSV:", out_csv, "\n")

# Write statistics
stats <- list(
  n_samples = nrow(valencia_data),
  module = module_name
)

if (!is.na(cst_col)) {
  stats$cst_counts <- as.list(table(valencia_data[[cst_col]]))
  stats$dominant_cst <- names(which.max(table(valencia_data[[cst_col]])))
}

if (!is.na(score_col)) {
  scores <- valencia_data[[score_col]]
  stats$score_mean <- round(mean(scores, na.rm = TRUE), 4)
  stats$score_sd <- round(sd(scores, na.rm = TRUE), 4)
  stats$score_min <- round(min(scores, na.rm = TRUE), 4)
  stats$score_max <- round(max(scores, na.rm = TRUE), 4)
}

stats_out <- file.path(out_dir, "valencia_stats.json")
write(toJSON(stats, auto_unbox = TRUE, pretty = TRUE), stats_out)
cat("[valencia] Wrote statistics:", stats_out, "\n")

cat("[valencia] Complete\n")
