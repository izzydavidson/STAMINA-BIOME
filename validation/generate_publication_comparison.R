#!/usr/bin/env Rscript
# generate_publication_comparison.R — Publication-ready multi-DB comparison figure
# Usage: Rscript generate_publication_comparison.R <body_site> <gt_profile> <out_png>
#         <csv1> <label1> <csv2> <label2> <csv3> <label3>

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(tidyr)
  library(gridExtra); library(grid); library(scales)
})

args       <- commandArgs(trailingOnly = TRUE)
BODY_SITE  <- args[1]
GT_PROFILE <- args[2]
OUT_PNG    <- args[3]
db_args    <- args[-(1:3)]
dbs <- list()
for (i in seq(1, length(db_args), by = 2))
  dbs[[length(dbs)+1]] <- list(csv = db_args[i], label = db_args[i+1])

site_meta <- list(
  gut  = list(full = "Gut",  color = "#1565C0"),
  oral = list(full = "Oral", color = "#E65100"),
  skin = list(full = "Skin", color = "#2E7D32")
)
site <- site_meta[[BODY_SITE]]

# Palette: grey for old DBs, site colour for custom
n_db  <- length(dbs)
greys <- c("#78909C", "#B0BEC5")
pal   <- c(greys[seq_len(n_db - 1)], site$color)
names(pal) <- sapply(dbs, `[[`, "label")

# ── Ground truth ──────────────────────────────────────────────────────────────
# Some CAMISIM genomes appear only at strain rank with broken TAXPATHSN;
# map their genome IDs to the correct species name.
GENOME_FIXES <- c(
  "Genome_B_longum"         = "Bifidobacterium longum",
  "Genome_P_melaninogenica" = "Prevotella melaninogenica",
  "Genome_P_gingivalis"     = "Porphyromonas gingivalis",
  "Genome_T_forsythia"      = "Tannerella forsythia",
  "Genome_A_naeslundii"     = "Actinomyces naeslundii",
  "Genome_M_globosa"        = "Malassezia"
)

parse_gt <- function(path) {
  rows      <- list()
  seen      <- character(0)
  all_lines <- readLines(path)

  # Pass 1: species-rank rows
  for (line in all_lines) {
    if (startsWith(line,"@") || !nzchar(trimws(line))) next
    p <- strsplit(line,"\t")[[1]]
    if (length(p)<5 || p[2]!="species") next
    pct <- suppressWarnings(as.numeric(p[5])); if (is.na(pct)) next
    name <- trimws(tail(strsplit(p[4],"\\|")[[1]],1))
    if (!nzchar(name) || name %in% seen) next
    seen <- c(seen, name)
    rows[[length(rows)+1]] <- data.frame(taxon=name, fraction=pct/100, stringsAsFactors=FALSE)
  }

  # Pass 2: strain-rank rows for genomes missing from species pass
  for (line in all_lines) {
    if (startsWith(line,"@") || !nzchar(trimws(line))) next
    p <- strsplit(line,"\t")[[1]]
    if (length(p)<5 || p[2]!="strain") next
    pct <- suppressWarnings(as.numeric(p[5])); if (is.na(pct)) next

    taxpathsn_parts <- strsplit(p[4],"\\|")[[1]]
    # Genome ID is the last whitespace-delimited token of the CAMI @comment
    # but more reliably: look for Genome_* in the strain name field (col 4 last element)
    strain_label <- trimws(tail(taxpathsn_parts, 1))
    genome_id <- regmatches(strain_label, regexpr("Genome_[A-Za-z_]+", strain_label))

    # Try second-to-last TAXPATHSN element as species name (valid if non-empty & contains space)
    candidate <- ""
    if (length(taxpathsn_parts) >= 2) {
      candidate <- trimws(taxpathsn_parts[length(taxpathsn_parts)-1])
    }
    valid_candidate <- nzchar(candidate) && grepl(" ", candidate) &&
                       !grepl("^[A-Z][a-z]+$", candidate) # reject single-word class/order names

    name <- if (valid_candidate) {
      candidate
    } else if (length(genome_id)==1 && genome_id %in% names(GENOME_FIXES)) {
      GENOME_FIXES[[genome_id]]
    } else {
      next
    }

    if (name %in% seen) next
    seen <- c(seen, name)
    rows[[length(rows)+1]] <- data.frame(taxon=name, fraction=pct/100, stringsAsFactors=FALSE)
  }

  do.call(rbind, rows)
}
gt_sp      <- parse_gt(GT_PROFILE)
n_true     <- nrow(gt_sp)
gt_vec     <- setNames(gt_sp$fraction, gt_sp$taxon)
true_names <- gt_sp$taxon

# ── Metrics ───────────────────────────────────────────────────────────────────
FP_THRESHOLD <- 0.001   # ignore detections below 0.1% as noise

compute_metrics <- function(d) {
  df       <- read.csv(d$csv, stringsAsFactors=FALSE) %>%
               filter(rank=="species") %>% mutate(fraction=as.numeric(fraction)) %>%
               filter(fraction >= FP_THRESHOLD)
  det_names <- df$taxon; det_vec <- setNames(df$fraction, df$taxon)
  tp <- intersect(true_names, det_names); fp <- setdiff(det_names, true_names)
  recovery <- round(100*length(tp)/n_true, 1)
  mae_pct  <- round(100*mean(sapply(true_names, function(s)
    abs(gt_vec[s] - ifelse(s %in% det_names, det_vec[s], 0)))), 3)
  matched <- tp
  r <- NA_real_; pval <- NA_real_
  if (length(matched) >= 3) {
    ct <- tryCatch(cor.test(sapply(matched,function(s)gt_vec[s]),
                            sapply(matched,function(s)det_vec[s])), error=function(e)NULL)
    if (!is.null(ct)) { r <- round(ct$estimate,4); pval <- signif(ct$p.value,3) }
  }
  prec <- if((length(tp)+length(fp))>0) round(length(tp)/(length(tp)+length(fp)),3) else NA_real_
  rec  <- round(length(tp)/n_true, 3)
  f1   <- if(!is.na(prec)&&(prec+rec)>0) round(2*prec*rec/(prec+rec),3) else NA_real_
  list(label=d$label, df=df, det_names=det_names, det_vec=det_vec,
       recovery=recovery, n_fp=length(fp), mae_pct=mae_pct,
       r=r, pval=pval, prec=prec, rec=rec, f1=f1)
}
results   <- lapply(dbs, compute_metrics)
labels    <- sapply(results, `[[`, "label")

# ── Shared theme ──────────────────────────────────────────────────────────────
pub_theme <- theme_classic(base_size=11) +
  theme(
    plot.title       = element_text(size=10, face="bold", margin=margin(b=4)),
    axis.title       = element_text(size=9),
    axis.text        = element_text(size=8),
    axis.text.x      = element_text(angle=25, hjust=1, size=8),
    panel.grid.major.y = element_line(colour="grey92", linewidth=0.4),
    panel.grid.major.x = element_blank(),
    legend.text      = element_text(size=8),
    legend.key.size  = unit(0.45,"cm")
  )

# ── Panel A: Recovery ─────────────────────────────────────────────────────────
df_A <- data.frame(db=factor(labels,levels=labels),
                   value=sapply(results,`[[`,"recovery"))
pA <- ggplot(df_A, aes(x=db, y=value, fill=db)) +
  geom_col(width=0.55, colour="white", linewidth=0.3, show.legend=FALSE) +
  geom_text(aes(label=paste0(value,"%")), vjust=-0.45, size=3.2, fontface="bold") +
  scale_fill_manual(values=pal) +
  scale_y_continuous(limits=c(0,120), expand=c(0,0)) +
  labs(title=sprintf("A  Species Recovery  (of %d true species)", n_true),
       x=NULL, y="Recovery (%)") +
  pub_theme

# ── Panel B: False Positives ──────────────────────────────────────────────────
df_B <- data.frame(db=factor(labels,levels=labels),
                   value=sapply(results,`[[`,"n_fp"))
pB <- ggplot(df_B, aes(x=db, y=value, fill=db)) +
  geom_col(width=0.55, colour="white", linewidth=0.3, show.legend=FALSE) +
  geom_text(aes(label=value), vjust=-0.45, size=3.2, fontface="bold") +
  scale_fill_manual(values=pal) +
  scale_y_continuous(limits=c(0, max(5, max(df_B$value)*1.4)), expand=c(0,0)) +
  labs(title="B  False Positives", x=NULL, y="FP species") +
  pub_theme

# ── Panel C: MAE (log scale) ──────────────────────────────────────────────────
df_C <- data.frame(db=factor(labels,levels=labels),
                   value=sapply(results,`[[`,"mae_pct"))
pC <- ggplot(df_C, aes(x=db, y=value, fill=db)) +
  geom_col(width=0.55, colour="white", linewidth=0.3, show.legend=FALSE) +
  geom_text(aes(label=paste0(value,"%")), vjust=-0.45, size=3.2, fontface="bold") +
  scale_fill_manual(values=pal) +
  scale_y_continuous(limits=c(0, max(0.5, max(df_C$value)*1.4)), expand=c(0,0)) +
  labs(title="C  Abundance MAE", x=NULL, y="MAE (%)") +
  pub_theme

# ── Panel D: Per-species horizontal bars ──────────────────────────────────────
sp_df <- gt_sp %>% rename(ground_truth = fraction)
for (res in results) {
  col <- setNames(data.frame(res$det_names, res$det_vec[res$det_names],
                             stringsAsFactors=FALSE), c("taxon", res$label))
  sp_df <- left_join(sp_df, col, by="taxon")
}
sp_long <- sp_df %>%
  pivot_longer(-taxon, names_to="source", values_to="abundance") %>%
  mutate(abundance = ifelse(is.na(abundance), 0, abundance) * 100,
         source    = factor(source, levels=c("ground_truth", labels)),
         taxon     = reorder(taxon, ifelse(source=="ground_truth", abundance, 0), max))

bar_pal <- c("ground_truth"="#455A64", pal)
bar_lbl <- c("Ground Truth", labels)

pD <- ggplot(sp_long, aes(x=abundance, y=taxon, fill=source)) +
  geom_col(position=position_dodge(width=0.78), width=0.72, colour="white", linewidth=0.2) +
  scale_fill_manual(values=bar_pal, labels=bar_lbl) +
  scale_x_continuous(expand=c(0,0)) +
  labs(title="D  Per-species Relative Abundance — Ground Truth vs STAMINA-BIOME",
       x="Relative Abundance (%)", y=NULL, fill=NULL) +
  theme_classic(base_size=11) +
  theme(plot.title    = element_text(size=10, face="bold", margin=margin(b=4)),
        axis.text.y   = element_text(size=8, face="italic"),
        axis.text.x   = element_text(size=8),
        legend.position = "bottom",
        legend.text   = element_text(size=8),
        legend.key.size = unit(0.42,"cm"),
        panel.grid.major.x = element_line(colour="grey92", linewidth=0.4))

# ── Panel E: Scatter ──────────────────────────────────────────────────────────
scat_df <- do.call(rbind, lapply(results, function(res) {
  matched <- intersect(true_names, res$det_names)
  if (!length(matched)) return(NULL)
  data.frame(gt  = sapply(matched, function(s) gt_vec[s])*100,
             det = sapply(matched, function(s) res$det_vec[s])*100,
             db  = res$label, stringsAsFactors=FALSE)
})) %>% mutate(db=factor(db,levels=labels))

xy_max <- max(scat_df$gt, scat_df$det) * 1.12
r_lbls <- sapply(results, function(res)
  sprintf("%s  r=%s", res$label, ifelse(is.na(res$r),"—",res$r)))

pE <- ggplot(scat_df, aes(x=gt, y=det, colour=db)) +
  geom_abline(slope=1, intercept=0, linetype="dashed", colour="grey55", linewidth=0.5) +
  geom_point(size=2.5, alpha=0.88) +
  scale_colour_manual(values=pal, labels=r_lbls) +
  scale_x_continuous(limits=c(0,xy_max), expand=c(0,0)) +
  scale_y_continuous(limits=c(0,xy_max), expand=c(0,0)) +
  labs(title="E  Ground Truth vs. Detected Abundance (Scatter)",
       x="Ground Truth Abundance (%)", y="Detected Abundance (%)", colour=NULL) +
  theme_classic(base_size=11) +
  theme(plot.title    = element_text(size=10, face="bold", margin=margin(b=4)),
        axis.text     = element_text(size=8),
        legend.position = "bottom",
        legend.text   = element_text(size=7.5),
        legend.key.size = unit(0.42,"cm"),
        panel.grid.major = element_line(colour="grey92", linewidth=0.4),
        aspect.ratio  = 1)

# ── Panel F: Stats table ──────────────────────────────────────────────────────
fmt <- function(x) ifelse(is.na(x), "—", as.character(x))
stats <- data.frame(Metric = c("Database","Bracken readlen","Recovery (%)","False Positives",
                               "MAE (%)","Pearson r","p-value","Precision","Recall","F1-score"),
                    stringsAsFactors=FALSE)
for (res in results)
  stats[[res$label]] <- c(res$label, "1500 bp",
                          paste0(res$recovery,"%"), as.character(res$n_fp),
                          paste0(res$mae_pct,"%"), fmt(res$r), fmt(res$pval),
                          fmt(res$prec), fmt(res$rec), fmt(res$f1))

hdr_fills <- c("#37474F", pal)
row_fills <- rep(c("white","#ECEFF1"), length.out=nrow(stats))
pF <- tableGrob(stats, rows=NULL,
  theme=ttheme_minimal(base_size=8.5,
    core    = list(fg_params=list(fontsize=8.5, hjust=0.5, x=0.5),
                   bg_params=list(fill=row_fills, col="grey80")),
    colhead = list(fg_params=list(fontsize=8.5, fontface="bold", col="white",
                                  hjust=0.5, x=0.5),
                   bg_params=list(fill=hdr_fills, col="grey80"))
  ))

# ── Assemble ──────────────────────────────────────────────────────────────────
title_grob <- textGrob(
  sprintf("STAMINA-BIOME %s Metagenome Validation: Database Progression and Abundance Accuracy", site$full),
  gp=gpar(fontsize=14, fontface="bold", col="#1A1A2E"))
sub_grob <- textGrob(
  sprintf("CAMISIM NanoSim3 simulation — %s mock metagenome | %d true species | conf=site-optimised, mhg=2",
          site$full, n_true),
  gp=gpar(fontsize=9, col="grey45"))

top_row  <- arrangeGrob(pA, pB, pC, ncol=3, widths=c(1,1,1))
mid_row  <- arrangeGrob(pD, pE, ncol=2, widths=c(1.45,1))
fig <- arrangeGrob(title_grob, sub_grob, top_row, mid_row, pF,
                   heights=c(0.045, 0.03, 0.24, 0.385, 0.30), ncol=1)

ggsave(OUT_PNG, fig, width=15, height=13, dpi=300, bg="white")
cat("Saved:", OUT_PNG, "\n")
