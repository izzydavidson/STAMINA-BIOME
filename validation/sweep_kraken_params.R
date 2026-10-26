#!/usr/bin/env Rscript
# =============================================================================
# STAMINA-BIOME Kraken2 Parameter Sweep — from existing .kraken2 per-read output
#
# Re-simulates confidence + minimum_hit_groups thresholds without re-running
# Kraken2, by parsing the k-mer hit string in each read's output line.
#
# Usage:
#   Rscript sweep_kraken_params.R <body_site> <gt_profile> <kraken2_file> \
#     <bracken_csv> <out_tsv> [out_png]
#
# Arguments:
#   body_site    : "gut", "oral", or "skin"
#   gt_profile   : CAMISIM taxonomic_profile_0.txt
#   kraken2_file : the .kraken2 per-read output file from the run
#   bracken_csv  : results.csv from the existing run (used only for species name
#                  normalisation reference — bracken was run with conf=0.02/mhg=2)
#   out_tsv      : path for the metrics table output
#   out_png      : (optional) heatmap figure
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(gridExtra)
  library(grid)
})

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a else b

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 5) {
  stop("Usage: sweep_kraken_params.R <body_site> <gt_profile> <kraken2_file> <bracken_csv> <out_tsv> [out_png]")
}

BODY_SITE    <- args[1]
GT_PROFILE   <- args[2]
KRAKEN2_FILE <- args[3]
BRACKEN_CSV  <- args[4]  # used for species-name reference only
OUT_TSV      <- args[5]
OUT_PNG      <- if (length(args) >= 6) args[6] else NULL

CONF_VALS <- c(0.01, 0.02, 0.03, 0.04, 0.05)
MHG_VALS  <- c(1L, 2L, 3L, 4L, 5L)

cat(sprintf("Body site: %s\n", BODY_SITE))
cat(sprintf("Sweep: conf %s | mhg %s\n",
            paste(CONF_VALS, collapse=","), paste(MHG_VALS, collapse=",")))

# ── Parse CAMI ground truth ──────────────────────────────────────────────────
parse_cami_profile <- function(path, rank_filter = "species") {
  lines <- readLines(path)
  rows  <- list()
  for (line in lines) {
    if (startsWith(line, "@") || !nzchar(trimws(line))) next
    parts <- strsplit(line, "\t")[[1]]
    if (length(parts) < 5) next
    rank <- parts[2]
    pct  <- suppressWarnings(as.numeric(parts[5]))
    if (rank != rank_filter || is.na(pct)) next
    name <- trimws(tail(strsplit(parts[4], "\\|")[[1]], 1))
    rows[[length(rows)+1]] <- data.frame(taxon=name, fraction=pct/100,
                                         stringsAsFactors=FALSE)
  }
  if (length(rows) == 0) return(NULL)
  do.call(rbind, rows)
}

gt_sp      <- parse_cami_profile(GT_PROFILE, "species")
if (is.null(gt_sp) || nrow(gt_sp) == 0) stop("No species in ground truth")
n_true     <- nrow(gt_sp)
true_names <- gt_sp$taxon
gt_vec     <- setNames(gt_sp$fraction, gt_sp$taxon)
cat(sprintf("Ground truth: %d species\n", n_true))

# ── Parse .kraken2 per-read file ─────────────────────────────────────────────
# Format: C/U  readid  "Name (taxid NNNN)"  seqlen  "tid:cnt tid:cnt ..."
cat(sprintf("Parsing %s ...\n", KRAKEN2_FILE))

con   <- file(KRAKEN2_FILE, "r")
reads <- list()
i     <- 0L
repeat {
  line <- readLines(con, n = 1L, warn = FALSE)
  if (length(line) == 0) break
  parts <- strsplit(line, "\t")[[1]]
  if (length(parts) < 5 || parts[1] != "C") next   # skip unclassified

  # Extract taxid from "Species name (taxid 12345)"
  taxid_match <- regmatches(parts[3], regexpr("(?<=\\(taxid )\\d+(?=\\))", parts[3], perl=TRUE))
  if (length(taxid_match) == 0) next
  taxid <- taxid_match

  # Extract species name — everything before " (taxid"
  sp_name <- trimws(sub("\\s*\\(taxid.*", "", parts[3]))

  # Parse k-mer hit string
  hit_str <- parts[5]
  tokens  <- strsplit(trimws(hit_str), " ")[[1]]
  tokens  <- tokens[nzchar(tokens)]

  tid_vec <- character(length(tokens))
  cnt_vec <- integer(length(tokens))
  for (j in seq_along(tokens)) {
    sc <- strsplit(tokens[j], ":")[[1]]
    tid_vec[j] <- sc[1]
    cnt_vec[j] <- suppressWarnings(as.integer(sc[2]))
  }
  cnt_vec[is.na(cnt_vec)] <- 0L

  total_kmers  <- sum(cnt_vec)
  direct_hits  <- sum(cnt_vec[tid_vec == taxid])

  # confidence approximation: fraction of k-mers directly hitting classified taxid
  conf_approx  <- if (total_kmers > 0) direct_hits / total_kmers else 0

  # hit groups: number of maximal contiguous blocks hitting classified taxid
  is_hit    <- tid_vec == taxid
  n_groups  <- sum(is_hit & c(FALSE, !is_hit[-length(is_hit)]))
  if (length(is_hit) > 0 && is_hit[1]) n_groups <- n_groups + 1L

  i <- i + 1L
  reads[[i]] <- list(sp_name=sp_name, taxid=taxid,
                     conf=conf_approx, mhg=n_groups,
                     total_kmers=total_kmers, direct_hits=direct_hits)
}
close(con)

read_df <- data.frame(
  sp_name      = sapply(reads, `[[`, "sp_name"),
  taxid        = sapply(reads, `[[`, "taxid"),
  conf         = sapply(reads, `[[`, "conf"),
  mhg          = as.integer(sapply(reads, `[[`, "mhg")),
  total_kmers  = as.integer(sapply(reads, `[[`, "total_kmers")),
  direct_hits  = as.integer(sapply(reads, `[[`, "direct_hits")),
  stringsAsFactors = FALSE
)
cat(sprintf("Parsed %d classified reads\n", nrow(read_df)))

# ── Load bracken CSV for species-name → taxid mapping ───────────────────────
# We need to match Kraken2 species names to ground truth names.
# Use the bracken results as the reference name set.
bracken_ref <- read.csv(BRACKEN_CSV, stringsAsFactors=FALSE) %>%
  filter(rank == "species") %>%
  select(taxon, fraction) %>%
  mutate(fraction = as.numeric(fraction))

# Build a name lookup: kraken2_name → normalised name
# Many Kraken2 names match bracken taxon names directly.
# Build lookup from read_df sp_name to bracken taxon where possible.
kr_names <- unique(read_df$sp_name)

# Match: exact, then partial
normalise_name <- function(kr_name, ref_names, gt_names) {
  all_names <- union(ref_names, gt_names)
  # Exact
  if (kr_name %in% all_names) return(kr_name)
  # Case-insensitive
  m <- all_names[tolower(all_names) == tolower(kr_name)]
  if (length(m) > 0) return(m[1])
  # First two words of kr_name vs first two words of ref
  w <- paste(strsplit(kr_name, " ")[[1]][1:min(2, length(strsplit(kr_name," ")[[1]]))], collapse=" ")
  m <- all_names[startsWith(tolower(all_names), tolower(w))]
  if (length(m) > 0) return(m[1])
  kr_name  # keep as-is
}

name_map <- setNames(
  vapply(kr_names, normalise_name,
         ref_names = bracken_ref$taxon,
         gt_names  = true_names,
         FUN.VALUE = ""),
  kr_names
)
read_df$norm_name <- name_map[read_df$sp_name]

# ── Sweep ────────────────────────────────────────────────────────────────────
results <- list()
for (conf_t in CONF_VALS) {
  for (mhg_t in MHG_VALS) {

    # Filter reads passing threshold
    passing <- read_df %>%
      filter(conf >= conf_t, mhg >= mhg_t)

    if (nrow(passing) == 0) {
      results[[length(results)+1]] <- data.frame(
        conf=conf_t, mhg=mhg_t,
        recovery=0, n_fp=0, mae_pct=round(mean(gt_vec)*100,3),
        pearson_r=NA_real_, precision=NA_real_, recall=0, f1=0,
        n_detected=0, stringsAsFactors=FALSE)
      next
    }

    # Per-taxon read count (proxy for abundance — Bracken won't be re-run,
    # so we use raw read counts normalised as relative abundance)
    per_taxon <- passing %>%
      group_by(norm_name) %>%
      summarise(reads = n(), .groups="drop") %>%
      mutate(fraction = reads / sum(reads))

    det_names <- per_taxon$norm_name
    det_vec   <- setNames(per_taxon$fraction, per_taxon$norm_name)

    true_det  <- intersect(true_names, det_names)
    fp        <- setdiff(det_names, true_names)
    recovery  <- round(100 * length(true_det) / n_true, 1)
    n_fp      <- length(fp)

    mae_vals  <- sapply(true_names, function(s)
      abs(gt_vec[s] - ifelse(s %in% det_names, det_vec[s], 0)))
    mae_pct   <- round(mean(mae_vals) * 100, 3)

    matched   <- intersect(true_names, det_names)
    pearson_r <- NA_real_
    if (length(matched) >= 3) {
      gt_m  <- sapply(matched, function(s) gt_vec[s])
      det_m <- sapply(matched, function(s) det_vec[s])
      pearson_r <- round(tryCatch(cor(gt_m, det_m), error=function(e) NA), 4)
    }

    precision <- if ((length(true_det) + n_fp) > 0)
      round(length(true_det) / (length(true_det) + n_fp), 3) else NA_real_
    recall    <- round(length(true_det) / n_true, 3)
    f1        <- if (!is.na(precision) && (precision + recall) > 0)
      round(2*precision*recall/(precision+recall), 3) else NA_real_

    results[[length(results)+1]] <- data.frame(
      conf=conf_t, mhg=mhg_t,
      recovery=recovery, n_fp=n_fp, mae_pct=mae_pct,
      pearson_r=pearson_r, precision=precision, recall=recall, f1=f1,
      n_detected=nrow(per_taxon), stringsAsFactors=FALSE)
  }
}

sweep_df <- do.call(rbind, results)
sweep_df$body_site <- BODY_SITE

cat("\n=== Sweep results ===\n")
print(sweep_df[order(sweep_df$conf, sweep_df$mhg),
               c("conf","mhg","recovery","n_fp","mae_pct","pearson_r","f1")],
      row.names=FALSE)

write.table(sweep_df, OUT_TSV, sep="\t", row.names=FALSE, quote=FALSE)
cat(sprintf("\nSaved TSV: %s\n", OUT_TSV))

# ── Optional heatmap figure ──────────────────────────────────────────────────
if (!is.null(OUT_PNG)) {
  site_colors <- c(gut="#2196F3", oral="#FF9800", skin="#4CAF50")
  base_col    <- site_colors[BODY_SITE] %||% "#607D8B"

  make_heatmap <- function(df, value_col, title, fmt_fn=identity, low="white", high=base_col) {
    df2 <- df %>% mutate(
      conf_lbl = sprintf("%.2f", conf),
      mhg_lbl  = as.character(mhg),
      val      = .data[[value_col]]
    )
    ggplot(df2, aes(x=mhg_lbl, y=conf_lbl, fill=val)) +
      geom_tile(colour="white", linewidth=0.5) +
      geom_text(aes(label=fmt_fn(val)), size=3, fontface="bold") +
      scale_fill_gradient(low=low, high=high, na.value="grey90", guide="none") +
      labs(title=title, x="Min Hit Groups", y="Confidence") +
      theme_minimal(base_size=9) +
      theme(plot.title=element_text(size=8, face="bold"),
            axis.text=element_text(size=7),
            panel.grid=element_blank())
  }

  pA <- make_heatmap(sweep_df, "recovery",  "A  Recovery (%)",
                     fmt_fn=function(x) paste0(x,"%"))
  pB <- make_heatmap(sweep_df, "n_fp",      "B  False Positives",
                     high="#f44336", low="white")
  pC <- make_heatmap(sweep_df, "mae_pct",   "C  Abundance MAE (%)",
                     fmt_fn=function(x) paste0(x,"%"), high="#FF9800", low="white")
  pD <- make_heatmap(sweep_df, "pearson_r", "D  Pearson r",
                     fmt_fn=function(x) ifelse(is.na(x),"—",as.character(x)))
  pE <- make_heatmap(sweep_df, "f1",        "E  F1-score",
                     fmt_fn=function(x) ifelse(is.na(x),"—",as.character(x)))

  site_full <- c(gut="Gut", oral="Oral", skin="Skin")[BODY_SITE] %||% BODY_SITE
  title_grob <- textGrob(
    sprintf("STAMINA-BIOME %s — stamina-biome-%s DB: Kraken2 Parameter Sweep", site_full, BODY_SITE),
    gp=gpar(fontsize=12, fontface="bold"))
  sub_grob <- textGrob(
    sprintf("Confidence 0.01–0.10 × Min Hit Groups 1–3 | %d true species | re-scored from existing .kraken2 output", n_true),
    gp=gpar(fontsize=8, col="grey40"))

  top  <- arrangeGrob(pA, pB, pC, ncol=3)
  bot  <- arrangeGrob(pD, pE, ncol=2)

  fig <- arrangeGrob(title_grob, sub_grob, top, bot,
                     heights=c(0.06, 0.04, 0.45, 0.45), ncol=1)

  ggsave(OUT_PNG, fig, width=10, height=9, dpi=150, bg="white")
  cat(sprintf("Saved PNG: %s\n", OUT_PNG))
}
