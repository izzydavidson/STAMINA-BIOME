#!/usr/bin/env Rscript
# =============================================================================
# STAMINA-BIOME Body-Site DB Validation Figure
# Same visual style as generate_bodysite_validation.R (vaginal).
# Compares core_nt, Custom DB v4, Custom DB v5 against CAMISIM ground truth.
# Uses taxid-based GT matching with CAMISIM mislabel corrections.
#
# Usage: Rscript generate_site_db_validation.R <gut|oral|skin>
# =============================================================================

suppressPackageStartupMessages({
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(gridExtra)
  library(grid)
  library(scales)
})

# Usage: Rscript generate_site_db_validation.R <gut|oral|skin> [outputs_dir] [gt_path] [out_dir]
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("Usage: Rscript generate_site_db_validation.R <gut|oral|skin> [outputs_dir] [gt_path] [out_dir]")
BODY_SITE <- tolower(args[1])
if (!BODY_SITE %in% c("gut", "oral", "skin")) stop("body_site must be gut, oral, or skin")

`%||%`    <- function(a, b) if (length(a) > 0) a else b
script_path <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) ".")
REPO_ROOT <- normalizePath(file.path(dirname(script_path), ".."), mustWork = FALSE)
BASE      <- if (length(args) >= 2) args[2] else file.path(REPO_ROOT, "outputs")
DESKTOP   <- if (length(args) >= 4) args[4] else path.expand("~/Desktop")

FP_THRESHOLD <- 0  # no threshold — every non-GT detection is a FP

# ── Site metadata ─────────────────────────────────────────────────────────────
default_gt <- list(
  gut  = file.path(path.expand("~"), "camisim_output/mock_metagenome_gut/nanopore/taxonomic_profile_0.txt"),
  oral = file.path(path.expand("~"), "camisim_output/mock_metagenome_oral/nanopore/taxonomic_profile_0.txt"),
  skin = file.path(path.expand("~"), "camisim_output/mock_metagenome_skin/nanopore/taxonomic_profile_0.txt")
)
site_meta <- list(
  gut  = list(full = "Gut",  color = "#2196F3", conf = 0.03,
              gt_path = if (length(args) >= 3) args[3] else default_gt$gut),
  oral = list(full = "Oral", color = "#FF9800", conf = 0.04,
              gt_path = if (length(args) >= 3) args[3] else default_gt$oral),
  skin = list(full = "Skin", color = "#4CAF50", conf = 0.03,
              gt_path = if (length(args) >= 3) args[3] else default_gt$skin)
)
site <- site_meta[[BODY_SITE]]

# ── DB paths ──────────────────────────────────────────────────────────────────
db_paths <- list(
  "core_nt"      = file.path(BASE, paste0(BODY_SITE, "_corent_v2/results/tables/results.csv")),
  "Custom DB v4" = file.path(BASE, paste0(BODY_SITE, "_customdb_v4/results/tables/results.csv")),
  "Custom DB v5" = file.path(BASE, paste0(BODY_SITE, "_v5_test/results/tables/results.csv"))
)
db_labels <- names(db_paths)

db_palette <- c(
  "Ground Truth"  = "#212121",
  "core_nt"       = "#1E88E5",
  "Custom DB v4"  = "#FF8F00",
  "Custom DB v5"  = "#2E7D32"
)

# ── Parse CAMISIM ground truth (taxid-based) ───────────────────────────────────
parse_gt <- function(path) {
  lines <- readLines(path)
  keep  <- !grepl("^@[^@]", lines) & nchar(trimws(lines)) > 0
  data_lines <- lines[keep]
  data_lines[1] <- sub("^@@", "", data_lines[1])
  df <- read.table(text = paste(data_lines, collapse = "\n"),
                   sep = "\t", header = TRUE, comment.char = "",
                   check.names = FALSE, stringsAsFactors = FALSE,
                   fill = TRUE, quote = "")
  sp <- df[df$RANK == "species", ]
  setNames(as.numeric(sp$PERCENTAGE) / 100, as.character(sp$TAXID))
}

gt <- parse_gt(site$gt_path)

# ── CAMISIM mislabel corrections (same as generate_db_comparison.R) ──────────
# CAMISIM profiles use wrong/outdated taxids for several genomes; substitute
# with actual NCBI species taxids verified from genome FASTA headers.
if (BODY_SITE == "gut") {
  # B. moraviense GCF_012932365.1 is labeled at genus (1678=Bifidobacterium) in CAMISIM
  gt["2675323"] <- 0.10
}
if (BODY_SITE == "oral") {
  # 4 genomes classified at wrong rank/taxid in CAMISIM profile
  gt["2479840"] <- 0.09    # P. marseillensis  (GCF_900625065.1, labeled as OTU=838)
  gt["28123"]   <- 0.075   # P. asaccharolytica (GCF_000212375.1, labeled as OTU=836)
  gt["70586"]   <- 0.04    # A. commune         (GCF_004362855.1, labeled as OTU=224471)
  gt["1655"]    <- 0.07    # A. naeslundii      (GCF_016127855.1, labeled at class=1760)
}
if (BODY_SITE == "skin") {
  # 3 genomes with outdated/wrong taxids in CAMISIM
  subst <- c("1743460" = "1747",  # Allopiophila luteata -> Cutibacterium acnes
             "38301"   = "38304", # C. minutissimum (old) -> C. tuberculostearicum
             "1697"    = "1703")  # C. ammoniagenes (wrong) -> Brevibacterium linens
  for (old in names(subst)) {
    new <- subst[[old]]
    if (old %in% names(gt)) { gt[new] <- gt[old]; gt <- gt[names(gt) != old] }
  }
}

gt_ids <- names(gt)
n_true <- length(gt_ids)
cat(sprintf("\nGround truth for %s: %d species (sum=%.3f)\n", BODY_SITE, n_true, sum(gt)))

# ── Abbreviated taxon labels ───────────────────────────────────────────────────
taxon_labels <- c(
  # Gut
  "818"     = "B. thetaiotaomicron", "853"  = "F. prausnitzii",
  "2675323" = "B. moraviense",       "239935" = "A. muciniphila",
  "166486"  = "R. intestinalis",     "210"  = "H. pylori",
  "562"     = "E. coli",             "1596" = "L. gasseri",
  "40520"   = "B. obeum",            "1502" = "C. perfringens",
  "817"     = "B. fragilis",         "165179" = "S. copri",
  # Oral
  "1303"    = "S. oralis",           "1318"   = "S. parasanguinis",
  "1655"    = "A. naeslundii",       "29466"  = "V. parvula",
  "2479840" = "P. marseillensis",    "851"    = "F. nucleatum",
  "732"     = "A. aphrophilus",      "28123"  = "P. asaccharolytica",
  "43675"   = "R. mucilaginosa",     "483"    = "N. cinerea",
  "70586"   = "A. commune",
  # Skin
  "1282"    = "S. epidermidis",      "1747"  = "C. acnes",
  "1280"    = "S. aureus",           "38304" = "C. tuberculostearicum",
  "76773"   = "M. globosa",          "1270"  = "M. luteus",
  "1283"    = "S. haemolyticus",     "1703"  = "B. linens"
)
label_of <- function(id) ifelse(id %in% names(taxon_labels), taxon_labels[id], id)

# ── Compute metrics per DB ─────────────────────────────────────────────────────
compute_metrics <- function(db_label, csv_path) {
  df <- tryCatch(read.csv(csv_path, stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0)
    return(list(db = db_label, recovery = NA, n_fp = NA, mae_pct = NA, f1 = NA,
                tp = 0, det_vec = setNames(numeric(0), character(0)), fp_taxa = character(0)))

  df <- df %>%
    filter(rank == "species") %>%
    mutate(taxid = as.character(taxid), fraction = as.numeric(fraction)) %>%
    filter(fraction > FP_THRESHOLD)

  det_ids <- df$taxid
  tp_ids  <- intersect(gt_ids, det_ids)
  fp_ids  <- setdiff(det_ids, gt_ids)
  det_vec <- setNames(df$fraction, df$taxid)

  recovery <- 100 * length(tp_ids) / n_true
  n_fp     <- length(fp_ids)
  mae_pct  <- 100 * mean(sapply(gt_ids, function(id)
    abs(gt[id] - ifelse(id %in% det_ids, det_vec[id], 0))))

  prec <- if ((length(tp_ids) + n_fp) > 0) length(tp_ids) / (length(tp_ids) + n_fp) else NA
  rec  <- length(tp_ids) / n_true
  f1   <- if (!is.na(prec) && (prec + rec) > 0) 2 * prec * rec / (prec + rec) else NA

  fp_taxa <- if (n_fp > 0) df$taxon[df$taxid %in% fp_ids] else character(0)

  list(db = db_label, recovery = recovery, n_fp = n_fp, mae_pct = mae_pct, f1 = f1,
       tp = length(tp_ids), det_vec = det_vec, fp_taxa = fp_taxa)
}

results <- mapply(compute_metrics, names(db_paths), db_paths, SIMPLIFY = FALSE)

cat("\n=== Metrics ===\n")
for (r in results) {
  cat(sprintf("  %-15s  Recovery=%.1f%%  FP=%d  MAE=%.2f%%  F1=%s\n",
              r$db, r$recovery, r$n_fp, r$mae_pct,
              ifelse(is.na(r$f1), "NA", sprintf("%.3f", r$f1))))
  if (length(r$fp_taxa) > 0)
    cat("    FPs:", paste(r$fp_taxa, collapse = ", "), "\n")
}

# ── Theme (same as vaginal script) ────────────────────────────────────────────
pub_theme <- theme_minimal(base_size = 9) +
  theme(
    plot.title         = element_text(size = 8, face = "bold"),
    axis.text.x        = element_text(size = 7, angle = 15, hjust = 1),
    panel.grid.major.x = element_blank()
  )

# ── Metrics data frame ─────────────────────────────────────────────────────────
metrics_df <- do.call(rbind, lapply(results, function(r) {
  data.frame(db = r$db, recovery = r$recovery, n_fp = r$n_fp,
             mae_pct = r$mae_pct, f1 = r$f1, stringsAsFactors = FALSE)
})) %>% mutate(db = factor(db, levels = db_labels))

# ── Panel A: Species Recovery ──────────────────────────────────────────────────
pA <- ggplot(metrics_df, aes(x = db, y = recovery, fill = db)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.0f%%", recovery)), vjust = -0.4,
            size = 3.5, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, 120), expand = c(0, 0),
                     labels = function(x) paste0(x, "%")) +
  labs(title = sprintf("A  Species Recovery\n(%% of %d true species detected)", n_true),
       x = NULL, y = "Recovery (%)") +
  pub_theme

# ── Panel B: False Positives ───────────────────────────────────────────────────
fp_max <- max(metrics_df$n_fp, na.rm = TRUE)
pB <- ggplot(metrics_df, aes(x = db, y = n_fp, fill = db)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = n_fp), vjust = -0.4, size = 3.5, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, max(5, fp_max * 1.5 + 1)), expand = c(0, 0)) +
  labs(title = "B  False Positives", x = NULL, y = "False positive species") +
  pub_theme

# ── Panel C: Abundance MAE ─────────────────────────────────────────────────────
mae_max <- max(metrics_df$mae_pct, na.rm = TRUE)
pC <- ggplot(metrics_df, aes(x = db, y = mae_pct, fill = db)) +
  geom_col(width = 0.6) +
  geom_text(aes(label = sprintf("%.1f%%", mae_pct)), vjust = -0.4,
            size = 3.5, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, mae_max * 1.6), expand = c(0, 0),
                     labels = function(x) paste0(x, "%")) +
  labs(title = "C  Abundance MAE", x = NULL, y = "MAE (%)") +
  pub_theme

# ── Panel D: Per-species abundance — GT + all 3 DBs ────────────────────────────
sp_levels <- c("Ground Truth", db_labels)
rows <- list()

for (id in gt_ids)
  rows[[length(rows) + 1]] <- data.frame(
    species = label_of(id), db = "Ground Truth", abundance = gt[id] * 100,
    stringsAsFactors = FALSE)

for (r in results)
  for (id in gt_ids)
    rows[[length(rows) + 1]] <- data.frame(
      species = label_of(id), db = r$db,
      abundance = ifelse(id %in% names(r$det_vec), r$det_vec[id] * 100, 0),
      stringsAsFactors = FALSE)

sp_df <- do.call(rbind, rows)
sp_df$db <- factor(sp_df$db, levels = sp_levels)

gt_order   <- sp_df %>% filter(db == "Ground Truth") %>% arrange(abundance) %>% pull(species)
sp_df$species <- factor(sp_df$species, levels = gt_order)

pD <- ggplot(sp_df, aes(x = abundance, y = species, fill = db)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.7) +
  scale_fill_manual(values = db_palette) +
  scale_x_continuous(expand = c(0, 0), labels = function(x) paste0(x, "%")) +
  labs(title = "D  Per-species Abundance — Ground Truth vs All Databases",
       x = "Relative Abundance (%)", y = NULL, fill = NULL) +
  theme_minimal(base_size = 9) +
  theme(plot.title      = element_text(size = 8, face = "bold"),
        axis.text.y     = element_text(size = 7, face = "italic"),
        legend.position = "bottom",
        legend.text     = element_text(size = 7))

# ── Panel E: Scatter (Custom DB v5 vs GT) ─────────────────────────────────────
r_v5  <- results[["Custom DB v5"]]
sc_df <- do.call(rbind, lapply(gt_ids, function(id) {
  data.frame(
    species = label_of(id),
    gt_pct  = gt[id] * 100,
    det_pct = ifelse(id %in% names(r_v5$det_vec), r_v5$det_vec[id] * 100, 0),
    stringsAsFactors = FALSE)
})) %>% filter(det_pct > 0)

pearson_r <- NA; p_val <- NA
if (nrow(sc_df) >= 3) {
  ct <- cor.test(sc_df$gt_pct, sc_df$det_pct, method = "pearson")
  pearson_r <- round(ct$estimate, 4)
  p_val     <- signif(ct$p.value, 3)
}
xy_max <- max(sc_df$gt_pct, sc_df$det_pct, na.rm = TRUE) * 1.1
r_label <- if (!is.na(pearson_r)) sprintf("r = %s", pearson_r) else "r = N/A"

pE <- ggplot(sc_df, aes(x = gt_pct, y = det_pct)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey60") +
  geom_point(color = site$color, size = 2.5, alpha = 0.85) +
  annotate("text", x = xy_max * 0.05, y = xy_max * 0.95,
           label = r_label, hjust = 0, size = 3, color = "grey30") +
  scale_x_continuous(limits = c(0, xy_max), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0, xy_max), expand = c(0, 0)) +
  labs(title = "E  Ground Truth vs. Custom DB v5 (Scatter)",
       x = "Ground Truth Abundance (%)", y = "Custom DB v5 Abundance (%)") +
  theme_minimal(base_size = 9) +
  theme(plot.title = element_text(size = 8, face = "bold"), aspect.ratio = 1)

# ── Panel F: Stats table ───────────────────────────────────────────────────────
stats_df <- data.frame(
  Database = sapply(results, `[[`, "db"),
  Recovery = sapply(results, function(r) sprintf("%.0f%%", r$recovery)),
  FP       = sapply(results, function(r) as.character(r$n_fp)),
  MAE      = sapply(results, function(r) sprintf("%.2f%%", r$mae_pct)),
  F1       = sapply(results, function(r) ifelse(is.na(r$f1), "—", sprintf("%.3f", r$f1))),
  stringsAsFactors = FALSE,
  row.names = NULL
)

pF <- tableGrob(
  stats_df, rows = NULL,
  theme = ttheme_minimal(
    core    = list(fg_params = list(fontsize = 8),
                   bg_params = list(fill = c("white", "#E3F2FD"), col = "grey80")),
    colhead = list(fg_params = list(fontsize = 8, fontface = "bold", col = "white"),
                   bg_params = list(fill = "#1565C0", col = "grey80", alpha = 0.85))
  )
)

# ── Assemble ───────────────────────────────────────────────────────────────────
title_grob <- textGrob(
  label = sprintf("STAMINA-BIOME %s Metagenome Validation: Database Comparison", site$full),
  gp    = gpar(fontsize = 13, fontface = "bold")
)
sub_grob <- textGrob(
  label = sprintf(
    "CAMISIM NanoSim3 simulation — %s mock metagenome | conf=%.2f mhg=4 | Bracken 1500 bp | %d ground truth species",
    site$full, site$conf, n_true),
  gp = gpar(fontsize = 8, col = "grey40")
)

top_row    <- arrangeGrob(pA, pB, pC, ncol = 3)
middle_row <- arrangeGrob(pD, pE, ncol = 2, widths = c(1.4, 1))

full_fig <- arrangeGrob(
  title_grob, sub_grob, top_row, middle_row, pF,
  heights = c(0.06, 0.04, 0.28, 0.42, 0.20),
  ncol = 1
)

out_path <- file.path(DESKTOP, sprintf("STAMINA-BIOME_%s_Validation.png", site$full))
ggsave(out_path, full_fig, width = 14, height = 11, dpi = 200, bg = "white")
cat("Saved:", out_path, "\n")
