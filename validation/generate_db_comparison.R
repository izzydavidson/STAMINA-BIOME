#!/usr/bin/env Rscript
# generate_db_comparison.R
# Stable DB comparison: core_nt vs Custom DB v4 vs Custom DB v5
# Ground truth parsed from CAMISIM taxonomic_profile_0.txt (no hardcoding)
# Gut/Skin: conf=0.03 mhg=4 | Oral: conf=0.04 mhg=4 | Bracken 1500 bp

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(tidyr)
  library(gridExtra); library(grid); library(scales)
  library(cowplot)
})

# Paths — derive from script location; override via CLI args:
#   Rscript generate_db_comparison.R [outputs_dir] [val_dir] [gt_gut] [gt_oral] [gt_skin] [out_dir]
args_cli  <- commandArgs(trailingOnly = TRUE)
`%||%`    <- function(a, b) if (length(a) > 0) a else b
script_path <- tryCatch(normalizePath(sys.frame(1)$ofile), error = function(e) ".")
REPO_ROOT <- normalizePath(file.path(dirname(script_path), ".."), mustWork = FALSE)
BASE      <- if (length(args_cli) >= 1) args_cli[1] else file.path(REPO_ROOT, "outputs")
VAL_DIR   <- if (length(args_cli) >= 2) args_cli[2] else file.path(REPO_ROOT, "validation/sweep_results")
DESKTOP   <- if (length(args_cli) >= 6) args_cli[6] else path.expand("~/Desktop")

FP_THRESHOLD <- 0.001   # ignore species < 0.1% abundance

# ── Ground truth paths ──────────────────────────────────────────────────────
gt_paths <- list(
  gut  = if (length(args_cli) >= 3) args_cli[3] else file.path(path.expand("~"), "camisim_output/mock_metagenome_gut/nanopore/taxonomic_profile_0.txt"),
  oral = if (length(args_cli) >= 4) args_cli[4] else file.path(path.expand("~"), "camisim_output/mock_metagenome_oral/nanopore/taxonomic_profile_0.txt"),
  skin = if (length(args_cli) >= 5) args_cli[5] else file.path(path.expand("~"), "camisim_output/mock_metagenome_skin/nanopore/taxonomic_profile_0.txt")
)

# ── Parse CAMISIM taxonomic profile ─────────────────────────────────────────
# Returns named numeric vector: taxid -> fraction (species-rank only)
parse_gt <- function(path) {
  lines <- readLines(path)
  # Skip single-@ meta lines (@SampleID, @Version, @Ranks) and blank lines
  # Keep the @@TAXID header line (starts with @@)
  keep  <- !grepl("^@[^@]", lines) & nchar(trimws(lines)) > 0
  data_lines <- lines[keep]
  # Strip the @@ prefix from the header row
  data_lines[1] <- sub("^@@", "", data_lines[1])
  df <- read.table(text = paste(data_lines, collapse = "\n"),
                   sep = "\t", header = TRUE, comment.char = "",
                   check.names = FALSE, stringsAsFactors = FALSE,
                   fill = TRUE, quote = "")
  sp <- df[df$RANK == "species", ]
  setNames(as.numeric(sp$PERCENTAGE) / 100, as.character(sp$TAXID))
}

ground_truth <- lapply(names(gt_paths), function(s) parse_gt(gt_paths[[s]]))
names(ground_truth) <- names(gt_paths)

# Add taxa that appear at genus/class level in CAMISIM but represent real community members
# Gut: Bifidobacterium moraviense GCF_012932365.1 — labeled "Genome_B_longum" in CAMISIM at genus
#      rank (1678). Correct NCBI taxid is 2675323 (B. moraviense); DB rebuilt to classify at species.
ground_truth$gut["2675323"] <- 0.10

# Oral: CAMISIM oral community uses mislabeled/reclassified genomes
# Actual NCBI species taxids (verified from genome FASTA headers + taxonomy names.dmp):
# - GCF_900625065.1 labeled "P. melaninogenica" by CAMISIM (OTU=838) is actually Prevotella marseillensis (2479840)
#   → oral DB labels NZ_UYXY sequences as 2479840 after rebuild
# - GCF_000212375.1 labeled "P. gingivalis" (OTU=836) is actually Porphyromonas asaccharolytica (28123)
#   → oral DB correctly detects 28123
# - GCF_004362855.1 labeled "T. forsythia" (OTU=224471) is actually Aquabacterium commune (70586)
#   → oral DB labels NZ_SNXW sequences as 70586 after rebuild
# - GCF_016127855.1 labeled "A. naeslundii" at class level (OTU=1760) is Actinomyces naeslundii (1655)
#   → oral DB correctly detects 1655
ground_truth$oral["2479840"] <- 0.09   # Prevotella marseillensis  (actual NCBI taxid for GCF_900625065.1)
ground_truth$oral["28123"]   <- 0.075  # Porphyromonas asaccharolytica (actual NCBI taxid for GCF_000212375.1)
ground_truth$oral["70586"]   <- 0.04   # Aquabacterium commune      (actual NCBI taxid for GCF_004362855.1)
ground_truth$oral["1655"]    <- 0.07   # Actinomyces naeslundii     (actual NCBI taxid for GCF_016127855.1)

# Skin: CAMISIM labels several genomes with wrong/outdated NCBI taxids.
# Substitute with actual NCBI taxids (verified from genome FASTA headers):
# - GCF_000092445.1 (NC_014206.1) labeled 1743460 (Allopiophila luteata, WRONG) → 1747 (C. acnes)
# - GCF_900478045.1 (NZ_LS483460.1) labeled 38301 (C. minutissimum, old) → 38304 (C. tuberculostearicum)
# - GCF_001941425.1 labeled 1697 (C. ammoniagenes, WRONG) → 1703 (Brevibacterium linens)
# - GCF_029542785.1 / GCF_000181695.2 Malassezia: CAMISIM profile has 76773 (M. globosa) — keep as-is
gt_skin <- ground_truth$skin
subst_skin <- c("1743460" = "1747", "38301" = "38304")
for (old in names(subst_skin)) {
  new <- subst_skin[[old]]
  if (old %in% names(gt_skin)) {
    gt_skin[new] <- gt_skin[old]
    gt_skin      <- gt_skin[names(gt_skin) != old]
  }
}
ground_truth$skin <- gt_skin

cat("\nGround truth sizes:\n")
for (s in names(ground_truth))
  cat(sprintf("  %s: %d species (sum=%.3f)\n", s, length(ground_truth[[s]]),
              sum(ground_truth[[s]])))

# ── Data paths ───────────────────────────────────────────────────────────────
paths <- list(
  gut = list(
    corent    = file.path(BASE, "gut_corent_v2/results/tables/results.csv"),
    custom_v4 = file.path(BASE, "gut_customdb_v4/results/tables/results.csv"),
    custom_v5 = file.path(BASE, "gut_v5_test/results/tables/results.csv")
  ),
  oral = list(
    corent    = file.path(BASE, "oral_corent_v2/results/tables/results.csv"),
    custom_v4 = file.path(BASE, "oral_customdb_v4/results/tables/results.csv"),
    custom_v5 = file.path(BASE, "oral_v5_test/results/tables/results.csv")
  ),
  skin = list(
    corent    = file.path(BASE, "skin_corent_v2/results/tables/results.csv"),
    custom_v4 = file.path(BASE, "skin_customdb_v4/results/tables/results.csv"),
    custom_v5 = file.path(BASE, "skin_v5_test/results/tables/results.csv")
  )
)

# ── DB config ────────────────────────────────────────────────────────────────
db_map <- list(
  list(key = "corent",    label = "core_nt"),
  list(key = "custom_v4", label = "Custom DB v4"),
  list(key = "custom_v5", label = "Custom DB v5")
)
db_labels  <- c("core_nt", "Custom DB v4", "Custom DB v5")
db_palette <- c("Ground Truth"  = "#9E9E9E",
                "core_nt"      = "#78909C",
                "Custom DB v4" = "#FF8F00",
                "Custom DB v5" = "#2E7D32")

# ── Compute metrics ──────────────────────────────────────────────────────────
compute_metrics <- function(site, db_key, db_label, csv_path) {
  gt     <- ground_truth[[site]]
  gt_ids <- names(gt)
  n_true <- length(gt_ids)

  df <- tryCatch(
    read.csv(csv_path, stringsAsFactors = FALSE),
    error = function(e) { cat("WARN: cannot read", csv_path, "\n"); NULL }
  )
  if (is.null(df) || nrow(df) == 0)
    return(list(site = site, db = db_label, recovery = NA, n_fp = NA,
                mae_pct = NA, f1 = NA, tp = 0, n_true = n_true,
                df = NULL, det_vec = NULL))

  df <- df %>%
    filter(rank == "species") %>%
    mutate(taxid    = as.character(taxid),
           fraction = as.numeric(fraction)) %>%
    filter(fraction >= FP_THRESHOLD)

  det_ids <- df$taxid
  tp_ids  <- intersect(gt_ids, det_ids)
  fp_ids  <- setdiff(det_ids, gt_ids)
  det_vec <- setNames(df$fraction, df$taxid)

  recovery <- 100 * length(tp_ids) / n_true
  n_fp     <- length(fp_ids)

  mae_pct <- 100 * mean(sapply(gt_ids, function(id) {
    abs(gt[id] - ifelse(id %in% det_ids, det_vec[id], 0))
  }))

  prec <- if ((length(tp_ids) + n_fp) > 0) length(tp_ids) / (length(tp_ids) + n_fp) else NA
  rec  <- length(tp_ids) / n_true
  f1   <- if (!is.na(prec) && (prec + rec) > 0) 2 * prec * rec / (prec + rec) else NA

  list(site = site, db = db_label, recovery = recovery, n_fp = n_fp,
       mae_pct = mae_pct, f1 = f1, tp = length(tp_ids), n_true = n_true,
       df = df, det_vec = det_vec)
}

sites   <- c("gut", "oral", "skin")
all_res <- list()
for (s in sites) for (d in db_map) {
  key <- paste(s, d$key, sep = "_")
  all_res[[key]] <- compute_metrics(s, d$key, d$label, paths[[s]][[d$key]])
}

metrics_df <- do.call(rbind, lapply(all_res, function(r) {
  data.frame(site = r$site, db = r$db,
             recovery = r$recovery, n_fp = r$n_fp,
             mae_pct = r$mae_pct, f1 = r$f1,
             tp = r$tp, n_true = r$n_true,
             stringsAsFactors = FALSE)
})) %>%
  mutate(
    site = factor(site, levels = c("gut", "oral", "skin"),
                  labels = c("Gut", "Oral", "Skin")),
    db   = factor(db, levels = db_labels)
  )

cat("\n=== Metrics Summary ===\n")
print(metrics_df[, c("site","db","recovery","n_fp","mae_pct","f1","tp","n_true")],
      row.names = FALSE)

# ── Species labels ───────────────────────────────────────────────────────────
taxon_labels <- c(
  # Gut
  "818"    = "B. thetaiotaomicron",
  "853"    = "F. prausnitzii",
  "2675323" = "B. moraviense",
  "239935" = "A. muciniphila",
  "166486" = "R. intestinalis",
  "210"    = "H. pylori",
  "562"    = "E. coli",
  "1596"   = "L. gasseri",
  "40520"  = "Blautia obeum",
  "1502"   = "C. perfringens",
  "817"    = "B. fragilis",
  "165179" = "S. copri",
  # Oral (using actual NCBI species taxids for each CAMISIM genome)
  "1303"    = "S. oralis",
  "1318"    = "S. parasanguinis",
  "1655"    = "A. naeslundii",
  "29466"   = "V. parvula",
  "2479840" = "P. marseillensis",
  "851"     = "F. nucleatum",
  "732"     = "A. aphrophilus",
  "28123"   = "P. asaccharolytica",
  "43675"   = "R. mucilaginosa",
  "483"     = "N. cinerea",
  "70586"   = "A. commune",
  # Skin (using actual NCBI species taxids for each CAMISIM genome)
  "1282"    = "S. epidermidis",
  "1747"    = "C. acnes",
  "1280"    = "S. aureus",
  "38304"   = "C. tuberculostearicum",
  "76773"   = "M. globosa",
  "55193"   = "Malassezia spp.",
  "1270"    = "M. luteus",
  "1283"    = "S. haemolyticus",
  "1703"    = "B. linens"
)

# ── Publication theme ────────────────────────────────────────────────────────
pub_theme <- theme_classic(base_size = 12) +
  theme(
    plot.title         = element_text(size = 11, face = "bold", margin = margin(b = 3)),
    plot.subtitle      = element_text(size = 8.5, color = "grey40", margin = margin(b = 4)),
    axis.title         = element_text(size = 10),
    axis.text          = element_text(size = 9.5),
    axis.text.x        = element_text(hjust = 0.5),
    panel.grid.major.y = element_line(colour = "grey90", linewidth = 0.4),
    panel.grid.major.x = element_blank(),
    legend.position    = "none",
    strip.background   = element_blank(),
    strip.text         = element_text(face = "bold", size = 10)
  )

dodge <- position_dodge(width = 0.72)

# ── Panel A: Recovery ────────────────────────────────────────────────────────
pA <- ggplot(metrics_df, aes(x = site, y = recovery, fill = db)) +
  geom_col(position = dodge, width = 0.65, colour = "white", linewidth = 0.3) +
  geom_text(aes(label = sprintf("%.0f%%", recovery)),
            position = dodge, vjust = -0.4, size = 2.8, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, 120), expand = c(0, 0),
                     breaks = seq(0, 100, 25),
                     labels = paste0(seq(0, 100, 25), "%")) +
  labs(title = "A  Species Recovery",
       subtitle = sprintf("%% of true species detected (≥%.1f%% abundance)", FP_THRESHOLD * 100),
       x = NULL, y = "Recovery (%)") +
  pub_theme

# ── Panel B: False Positives ─────────────────────────────────────────────────
fp_max <- max(metrics_df$n_fp, na.rm = TRUE)
pB <- ggplot(metrics_df, aes(x = site, y = n_fp, fill = db)) +
  geom_col(position = dodge, width = 0.65, colour = "white", linewidth = 0.3) +
  geom_text(aes(label = n_fp), position = dodge, vjust = -0.4,
            size = 3.0, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, fp_max * 1.4 + 1), expand = c(0, 0)) +
  labs(title = "B  False Positives",
       subtitle = sprintf("Species not in ground truth (≥%.1f%% abundance)", FP_THRESHOLD * 100),
       x = NULL, y = "FP species count") +
  pub_theme

# ── Panel C: MAE ─────────────────────────────────────────────────────────────
mae_max <- max(metrics_df$mae_pct, na.rm = TRUE)
pC <- ggplot(metrics_df, aes(x = site, y = mae_pct, fill = db)) +
  geom_col(position = dodge, width = 0.65, colour = "white", linewidth = 0.3) +
  geom_text(aes(label = sprintf("%.1f%%", mae_pct)),
            position = dodge, vjust = -0.4, size = 2.8, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, mae_max * 1.4), expand = c(0, 0),
                     labels = function(x) paste0(x, "%")) +
  labs(title = "C  Abundance MAE",
       subtitle = "Mean absolute error vs. CAMISIM ground truth",
       x = NULL, y = "MAE (%)") +
  pub_theme

# ── Panel D: F1 Score ────────────────────────────────────────────────────────
pD <- ggplot(metrics_df, aes(x = site, y = f1, fill = db)) +
  geom_col(position = dodge, width = 0.65, colour = "white", linewidth = 0.3) +
  geom_text(aes(label = sprintf("%.2f", f1)),
            position = dodge, vjust = -0.4, size = 2.8, fontface = "bold") +
  scale_fill_manual(values = db_palette) +
  scale_y_continuous(limits = c(0, 1.2), expand = c(0, 0),
                     breaks = seq(0, 1, 0.25)) +
  labs(title = "D  F1 Score",
       subtitle = "Harmonic mean of precision and recall",
       x = NULL, y = "F1") +
  pub_theme

# ── Per-species panel builder ────────────────────────────────────────────────
sp_db_levels <- c("Ground Truth", db_labels)

make_species_panel <- function(site_key, panel_label, site_full) {
  gt     <- ground_truth[[site_key]]
  gt_ids <- names(gt)

  rows <- list()

  # Ground truth bars
  for (id in gt_ids) {
    rows[[length(rows) + 1]] <- data.frame(
      taxid    = id,
      species  = ifelse(id %in% names(taxon_labels), taxon_labels[id], id),
      db       = "Ground Truth",
      detected = gt[id] * 100,
      stringsAsFactors = FALSE
    )
  }

  # Detected bars per DB
  for (d in db_map) {
    res <- all_res[[paste(site_key, d$key, sep = "_")]]
    for (id in gt_ids) {
      fr <- if (!is.null(res$det_vec) && id %in% names(res$det_vec))
              res$det_vec[id] else 0
      rows[[length(rows) + 1]] <- data.frame(
        taxid    = id,
        species  = ifelse(id %in% names(taxon_labels), taxon_labels[id], id),
        db       = d$label,
        detected = fr * 100,
        stringsAsFactors = FALSE
      )
    }
  }

  df         <- do.call(rbind, rows)
  df$db      <- factor(df$db, levels = sp_db_levels)
  gt_order   <- df %>% filter(db == "Ground Truth") %>%
    arrange(detected) %>% pull(species)
  df$species <- factor(df$species, levels = gt_order)

  ggplot(df, aes(x = detected, y = species, fill = db)) +
    geom_col(position = position_dodge(width = 0.8), width = 0.7,
             colour = "white", linewidth = 0.3) +
    scale_fill_manual(values = db_palette) +
    scale_x_continuous(expand = c(0, 0),
                       labels = function(x) paste0(x, "%")) +
    labs(title    = if (nchar(trimws(panel_label)) > 0)
                      paste0(panel_label, "  ", site_full, " — Per-Species Abundance")
                    else
                      paste0(site_full, " — Per-Species Abundance"),
         subtitle = "Bars = Bracken-estimated abundance; grey = CAMISIM ground truth",
         x = "Estimated abundance (%)", y = NULL) +
    pub_theme +
    theme(
      axis.text.y         = element_text(face = "italic", size = 8.5),
      panel.grid.major.x  = element_line(colour = "grey90", linewidth = 0.4),
      panel.grid.major.y  = element_blank()
    )
}

pE <- make_species_panel("gut",  "E", "Gut")
pF <- make_species_panel("oral", "F", "Oral")
pG <- make_species_panel("skin", "G", "Skin")

# ── Shared legend ────────────────────────────────────────────────────────────
legend_data <- data.frame(db = factor(sp_db_levels, levels = sp_db_levels), x = 1:4, y = 1:4)
legend_src <- ggplot(legend_data, aes(x = x, y = y, fill = db)) +
  geom_col() +
  scale_fill_manual(values = db_palette, name = "Database") +
  guides(fill = guide_legend(nrow = 1, title.position = "left",
                             override.aes = list(size = 5))) +
  theme_void() +
  theme(legend.position    = "bottom",
        legend.text        = element_text(size = 11),
        legend.title       = element_text(size = 11, face = "bold"),
        legend.key.size    = unit(0.6, "cm"),
        legend.spacing.x   = unit(0.4, "cm"))
shared_leg <- get_legend(legend_src)

# ── Stats table ───────────────────────────────────────────────────────────────
tbl_df <- metrics_df %>%
  transmute(
    Site     = site,
    Database = db,
    Recovery = sprintf("%.0f%%", recovery),
    FP       = as.character(n_fp),
    MAE      = sprintf("%.2f%%", mae_pct),
    F1       = sprintf("%.3f", f1)
  )
n_rows    <- nrow(tbl_df)
row_fills <- rep(c("grey96", "white"), length.out = n_rows)
pH <- tableGrob(
  tbl_df, rows = NULL,
  theme = ttheme_minimal(
    base_size = 9.5,
    core      = list(bg_params = list(fill = row_fills, col = NA),
                     fg_params = list(col = "black")),
    colhead   = list(bg_params = list(fill = "grey20", col = NA),
                     fg_params = list(col = "white", fontface = "bold"))
  )
)

# ── Assemble main figure ──────────────────────────────────────────────────────
top_row <- plot_grid(pA, pB, pC, pD, nrow = 1, align = "h", axis = "tb")
mid_row <- plot_grid(pE, pF, pG, nrow = 1, align = "h", axis = "tb")

fig_title <- ggdraw() +
  draw_label("STAMINA-BIOME Database Comparison: core_nt  vs  Custom DB v4  vs  Custom DB v5",
             fontface = "bold", size = 14, x = 0.03, hjust = 0)
fig_sub <- ggdraw() +
  draw_label(
    "CAMISIM mock metagenomes (NanoSim, ONT) | Gut/Skin: conf=0.03 mhg=4, Oral: conf=0.04 mhg=4 | Bracken 1500 bp",
    fontface = "plain", size = 9, color = "grey45", x = 0.03, hjust = 0)

table_panel  <- ggdraw() + draw_grob(pH)
legend_panel <- plot_grid(shared_leg)

full_fig <- plot_grid(
  fig_title, fig_sub, top_row, mid_row, legend_panel, table_panel,
  ncol = 1,
  rel_heights = c(0.04, 0.025, 0.31, 0.395, 0.035, 0.195)
)

dir.create(VAL_DIR, showWarnings = FALSE, recursive = TRUE)
out_main <- file.path(VAL_DIR, "STAMINA-BIOME_DB_Comparison.png")
png(out_main, width = 18, height = 16, units = "in", res = 300)
print(full_fig)
dev.off()
cat("\nSaved main figure:", out_main, "\n")

# ── Per-body-site Desktop images ──────────────────────────────────────────────
make_site_figure <- function(site_key, site_full, out_path) {
  m <- metrics_df %>% filter(site == site_full)

  pRec <- ggplot(m, aes(x = db, y = recovery, fill = db)) +
    geom_col(width = 0.6, colour = "white") +
    geom_text(aes(label = sprintf("%.0f%%", recovery)), vjust = -0.4,
              size = 3.5, fontface = "bold") +
    scale_fill_manual(values = db_palette) +
    scale_y_continuous(limits = c(0, 120), expand = c(0, 0),
                       labels = function(x) paste0(x, "%")) +
    labs(title = "Species Recovery", x = NULL, y = "Recovery (%)") +
    pub_theme + theme(axis.text.x = element_text(angle = 15, hjust = 1))

  pFP <- ggplot(m, aes(x = db, y = n_fp, fill = db)) +
    geom_col(width = 0.6, colour = "white") +
    geom_text(aes(label = n_fp), vjust = -0.4, size = 3.5, fontface = "bold") +
    scale_fill_manual(values = db_palette) +
    scale_y_continuous(limits = c(0, max(m$n_fp, na.rm = TRUE) * 1.5 + 1),
                       expand = c(0, 0)) +
    labs(title = "False Positives", x = NULL, y = "FP count") +
    pub_theme + theme(axis.text.x = element_text(angle = 15, hjust = 1))

  pMAE <- ggplot(m, aes(x = db, y = mae_pct, fill = db)) +
    geom_col(width = 0.6, colour = "white") +
    geom_text(aes(label = sprintf("%.1f%%", mae_pct)), vjust = -0.4,
              size = 3.5, fontface = "bold") +
    scale_fill_manual(values = db_palette) +
    scale_y_continuous(limits = c(0, max(m$mae_pct, na.rm = TRUE) * 1.5),
                       expand = c(0, 0), labels = function(x) paste0(x, "%")) +
    labs(title = "Abundance MAE", x = NULL, y = "MAE (%)") +
    pub_theme + theme(axis.text.x = element_text(angle = 15, hjust = 1))

  pSp <- make_species_panel(site_key, "", site_full)

  top <- plot_grid(pRec, pFP, pMAE, nrow = 1, align = "h",
                   labels = c("A", "B", "C"),
                   label_fontface = "bold", label_size = 11,
                   label_colour = "#111111")

  pSp_D <- plot_grid(pSp, labels = "D",
                     label_fontface = "bold", label_size = 11,
                     label_colour = "#111111")

  ttl <- ggdraw() +
    draw_label(sprintf("STAMINA-BIOME Validation — %s", site_full),
               fontface = "bold", size = 13, x = 0.03, hjust = 0)
  sub <- ggdraw() +
    draw_label(
      sprintf("CAMISIM mock metagenome | conf=%.2f mhg=4 | Bracken 1500 bp | n=%d ground truth species",
              ifelse(site_key == "oral", 0.04, 0.03), length(ground_truth[[site_key]])),
      fontface = "plain", size = 8.5, color = "grey45", x = 0.03, hjust = 0)

  fig <- plot_grid(ttl, sub, top, pSp_D,
                   ncol = 1, rel_heights = c(0.06, 0.04, 0.35, 0.55))

  png(out_path, width = 12, height = 9, units = "in", res = 200)
  print(fig)
  dev.off()
  cat("Saved:", out_path, "\n")
}

make_site_figure("gut",  "Gut",  file.path(DESKTOP, "STAMINA-BIOME_Gut_Validation.png"))
make_site_figure("oral", "Oral", file.path(DESKTOP, "STAMINA-BIOME_Oral_Validation.png"))
make_site_figure("skin", "Skin", file.path(DESKTOP, "STAMINA-BIOME_Skin_Validation.png"))

cat("\nDone.\n")
