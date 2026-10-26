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

# Generate CST distribution bar chart
if (!is.na(cst_col)) {
  cst_counts <- table(valencia_data[[cst_col]])
  cst_df <- as.data.frame(cst_counts)
  colnames(cst_df) <- c("CST", "count")
  cst_df <- cst_df[order(-cst_df$count), ]

  # CST colors (standard CST coloring)
  cst_colors <- c(
    "I" = "#1f77b4",
    "II" = "#ff7f0e",
    "III" = "#2ca02c",
    "IV-A" = "#d62728",
    "IV-B" = "#9467bd",
    "IV-C" = "#8c564b",
    "V" = "#e377c2",
    "I-A" = "#1f77b4",
    "I-B" = "#aec7e8",
    "III-A" = "#2ca02c",
    "III-B" = "#98df8a"
  )

  out_png <- file.path(out_dir, "cst_distribution.png")

  png(out_png, width = 600, height = 500, res = 150, bg = "white")
  par(mar = c(6, 4, 3, 1))

  colors_to_use <- sapply(as.character(cst_df$CST), function(x) {
    if (x %in% names(cst_colors)) cst_colors[x] else "gray50"
  })

  bp <- barplot(cst_df$count,
                names.arg = cst_df$CST,
                col = colors_to_use,
                border = NA,
                las = 2,
                ylab = "Number of Samples",
                main = "CST Distribution",
                ylim = c(0, max(cst_df$count) * 1.2))

  # Add count labels
  text(bp, cst_df$count, labels = cst_df$count, pos = 3, cex = 0.8)

  dev.off()
  cat("[valencia] Generated CST distribution chart:", out_png, "\n")
}

# Generate SubCST distribution if available
if (!is.na(subcst_col)) {
  subcst_counts <- table(valencia_data[[subcst_col]])
  subcst_df <- as.data.frame(subcst_counts)
  colnames(subcst_df) <- c("SubCST", "count")
  subcst_df <- subcst_df[order(-subcst_df$count), ]

  out_png <- file.path(out_dir, "subcst_distribution.png")

  png(out_png, width = 700, height = 500, res = 150, bg = "white")
  par(mar = c(7, 4, 3, 1))

  colors_to_use <- rainbow(nrow(subcst_df), s = 0.7, v = 0.8)

  bp <- barplot(subcst_df$count,
                names.arg = subcst_df$SubCST,
                col = colors_to_use,
                border = NA,
                las = 2,
                ylab = "Number of Samples",
                main = "Sub-CST Distribution",
                ylim = c(0, max(subcst_df$count) * 1.2),
                cex.names = 0.7)

  text(bp, subcst_df$count, labels = subcst_df$count, pos = 3, cex = 0.7)

  dev.off()
  cat("[valencia] Generated SubCST distribution chart:", out_png, "\n")
}

# Generate similarity score heatmap if multiple samples
if (length(sim_cols) > 0 && nrow(valencia_data) > 0) {
  # Prepare similarity matrix
  sim_data <- valencia_data[, sim_cols, drop = FALSE]
  rownames(sim_data) <- valencia_data[[sample_col]]

  # Clean column names (remove _sim suffix)
  colnames(sim_data) <- sub("_sim$", "", colnames(sim_data))

  # Convert to matrix
  sim_mat <- as.matrix(sim_data)

  if (nrow(sim_mat) > 1) {
    # Multiple samples - create heatmap
    out_png <- file.path(out_dir, "similarity_heatmap.png")

    n_samples <- nrow(sim_mat)
    n_csts <- ncol(sim_mat)

    png(out_png, width = max(500, n_csts * 50), height = max(400, n_samples * 30), res = 150, bg = "white")

    layout(matrix(c(1, 2), nrow = 1), widths = c(4, 1))
    par(mar = c(8, 10, 3, 1))

    # Color palette
    n_colors <- 100
    colors <- colorRampPalette(c("white", "yellow", "orange", "red"))(n_colors)

    image(1:n_csts, 1:n_samples, t(sim_mat),
          col = colors,
          xlab = "", ylab = "",
          axes = FALSE,
          main = "VALENCIA Similarity Scores")

    axis(1, at = 1:n_csts, labels = colnames(sim_mat), las = 2, cex.axis = 0.7)
    axis(2, at = 1:n_samples, labels = rownames(sim_mat), las = 1, cex.axis = 0.7)

    # Colorbar
    par(mar = c(8, 1, 3, 3))
    image(1, seq(0, 1, length.out = n_colors), t(matrix(1:n_colors)),
          col = colors,
          xlab = "", ylab = "",
          axes = FALSE)
    axis(4, at = c(0, 0.5, 1), labels = c("0", "0.5", "1"), las = 1, cex.axis = 0.7)
    mtext("Similarity", side = 4, line = 2, cex = 0.7)

    dev.off()
    cat("[valencia] Generated similarity heatmap:", out_png, "\n")
  } else {
    # Single sample - create bar chart of similarities
    out_png <- file.path(out_dir, "similarity_scores.png")

    png(out_png, width = 600, height = 400, res = 150, bg = "white")
    par(mar = c(8, 4, 3, 1))

    vals <- as.numeric(sim_mat[1, ])
    names(vals) <- colnames(sim_mat)
    vals <- sort(vals, decreasing = TRUE)

    colors <- colorRampPalette(c("lightblue", "darkblue"))(length(vals))
    colors <- colors[rank(-vals)]

    bp <- barplot(vals,
                  col = colors,
                  border = NA,
                  las = 2,
                  ylab = "Similarity Score",
                  main = paste("VALENCIA Similarity -", valencia_data[[sample_col]][1]),
                  ylim = c(0, 1),
                  cex.names = 0.8)

    # Add value labels
    text(bp, vals, labels = round(vals, 3), pos = 3, cex = 0.6)

    dev.off()
    cat("[valencia] Generated similarity scores chart:", out_png, "\n")
  }
}

# Generate score distribution if available
if (!is.na(score_col)) {
  scores <- valencia_data[[score_col]]
  scores <- scores[!is.na(scores)]

  if (length(scores) > 0) {
    out_png <- file.path(out_dir, "score_distribution.png")

    png(out_png, width = 500, height = 400, res = 150, bg = "white")
    par(mar = c(5, 4, 3, 1))

    hist(scores,
         breaks = 20,
         col = "steelblue",
         border = "white",
         xlab = "VALENCIA Score",
         ylab = "Frequency",
         main = "VALENCIA Score Distribution",
         xlim = c(0, 1))

    # Add mean line
    abline(v = mean(scores), col = "red", lwd = 2, lty = 2)
    legend("topleft",
           legend = paste("Mean:", round(mean(scores), 3)),
           col = "red",
           lty = 2,
           lwd = 2,
           bty = "n",
           cex = 0.8)

    dev.off()
    cat("[valencia] Generated score distribution:", out_png, "\n")
  }
}

# Write summary CSV
summary_df <- data.frame(
  sample_id = valencia_data[[sample_col]],
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
