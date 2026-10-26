#!/usr/bin/env Rscript
# generate_bodysite_comparison.R
# Multi-DB comparison figure (mirrors STAMINA-BIOME_Vaginal_Validation.png layout)
# Usage: Rscript generate_bodysite_comparison.R <body_site> <gt_profile> <out_png>
#   <csv1> <label1> <csv2> <label2> <csv3> <label3>

suppressPackageStartupMessages({
  library(ggplot2); library(dplyr); library(tidyr)
  library(gridExtra); library(grid); library(scales)
})

args <- commandArgs(trailingOnly = TRUE)
BODY_SITE  <- args[1]
GT_PROFILE <- args[2]
OUT_PNG    <- args[3]
# Pairs: csv label csv label ...
db_args <- args[-(1:3)]
dbs <- list()
for (i in seq(1, length(db_args), by=2))
  dbs[[length(dbs)+1]] <- list(csv=db_args[i], label=db_args[i+1])

site_meta <- list(
  gut  = list(full="Gut",  color="#2196F3"),
  oral = list(full="Oral", color="#FF9800"),
  skin = list(full="Skin", color="#4CAF50")
)
site <- site_meta[[BODY_SITE]]

# ── Ground truth ──────────────────────────────────────────────────────────────
parse_gt <- function(path) {
  rows <- list()
  for (line in readLines(path)) {
    if (startsWith(line,"@") || !nzchar(trimws(line))) next
    p <- strsplit(line,"\t")[[1]]; if (length(p)<5 || p[2]!="species") next
    pct <- suppressWarnings(as.numeric(p[5])); if (is.na(pct)) next
    name <- trimws(tail(strsplit(p[4],"\\|")[[1]],1))
    rows[[length(rows)+1]] <- data.frame(taxon=name, fraction=pct/100, stringsAsFactors=FALSE)
  }
  do.call(rbind, rows)
}
gt_sp      <- parse_gt(GT_PROFILE)
n_true     <- nrow(gt_sp)
gt_vec     <- setNames(gt_sp$fraction, gt_sp$taxon)
true_names <- gt_sp$taxon

# ── Load results & compute metrics ────────────────────────────────────────────
results <- lapply(dbs, function(d) {
  df   <- read.csv(d$csv, stringsAsFactors=FALSE) %>%
    filter(rank=="species") %>% mutate(fraction=as.numeric(fraction))
  det_names <- df$taxon; det_vec <- setNames(df$fraction, df$taxon)
  tp <- intersect(true_names, det_names); fp <- setdiff(det_names, true_names)
  recovery <- round(100*length(tp)/n_true, 1)
  mae_pct  <- round(100*mean(sapply(true_names,function(s) abs(gt_vec[s]-ifelse(s %in% det_names,det_vec[s],0)))),3)
  matched  <- intersect(true_names, det_names)
  r <- NA; pval <- NA
  if (length(matched)>=3) {
    ct <- tryCatch(cor.test(sapply(matched,function(s)gt_vec[s]),
                            sapply(matched,function(s)det_vec[s]),method="pearson"),error=function(e)NULL)
    if (!is.null(ct)) { r <- round(ct$estimate,4); pval <- signif(ct$p.value,3) }
  }
  prec <- if((length(tp)+length(fp))>0) round(length(tp)/(length(tp)+length(fp)),3) else NA
  rec  <- round(length(tp)/n_true,3)
  f1   <- if(!is.na(prec)&&(prec+rec)>0) round(2*prec*rec/(prec+rec),3) else NA
  list(label=d$label, df=df, det_names=det_names, det_vec=det_vec,
       recovery=recovery, n_fp=length(fp), mae_pct=mae_pct,
       r=r, pval=pval, prec=prec, rec=rec, f1=f1)
})

labels    <- sapply(results, `[[`, "label")
n_db      <- length(results)
pal       <- c("#607D8B", "#FF7043", site$color)
if (n_db > length(pal)) pal <- scales::hue_pal()(n_db)
names(pal) <- labels

# ── Panel A: Recovery ─────────────────────────────────────────────────────────
df_A <- data.frame(db=labels, value=sapply(results,`[[`,"recovery"),
                   stringsAsFactors=FALSE) %>% mutate(db=factor(db,levels=labels))
pA <- ggplot(df_A,aes(x=db,y=value,fill=db)) +
  geom_col(width=0.55,show.legend=FALSE) +
  geom_text(aes(label=paste0(value,"%")),vjust=-0.4,size=3,fontface="bold") +
  scale_fill_manual(values=pal) +
  scale_y_continuous(limits=c(0,118),expand=c(0,0)) +
  labs(title=sprintf("A  Species Recovery\n(%% of %d true species)",n_true),x=NULL,y="Recovery (%)") +
  theme_minimal(base_size=9) +
  theme(plot.title=element_text(size=8,face="bold"),
        axis.text.x=element_text(size=7,angle=20,hjust=1),
        panel.grid.major.x=element_blank())

# ── Panel B: False Positives ──────────────────────────────────────────────────
df_B <- data.frame(db=labels, value=sapply(results,`[[`,"n_fp"),
                   stringsAsFactors=FALSE) %>% mutate(db=factor(db,levels=labels))
pB <- ggplot(df_B,aes(x=db,y=value,fill=db)) +
  geom_col(width=0.55,show.legend=FALSE) +
  geom_text(aes(label=value),vjust=-0.4,size=3,fontface="bold") +
  scale_fill_manual(values=pal) +
  scale_y_continuous(limits=c(0,max(5,max(df_B$value)*1.4)),expand=c(0,0)) +
  labs(title="B  False Positives",x=NULL,y="False positive species") +
  theme_minimal(base_size=9) +
  theme(plot.title=element_text(size=8,face="bold"),
        axis.text.x=element_text(size=7,angle=20,hjust=1),
        panel.grid.major.x=element_blank())

# ── Panel C: MAE ──────────────────────────────────────────────────────────────
df_C <- data.frame(db=labels, value=sapply(results,`[[`,"mae_pct"),
                   stringsAsFactors=FALSE) %>% mutate(db=factor(db,levels=labels))
pC <- ggplot(df_C,aes(x=db,y=value,fill=db)) +
  geom_col(width=0.55,show.legend=FALSE) +
  geom_text(aes(label=paste0(value,"%")),vjust=-0.4,size=3,fontface="bold") +
  scale_fill_manual(values=pal) +
  scale_y_continuous(limits=c(0,max(0.5,max(df_C$value)*1.4)),expand=c(0,0)) +
  labs(title="C  Abundance MAE",x=NULL,y="MAE (%)") +
  theme_minimal(base_size=9) +
  theme(plot.title=element_text(size=8,face="bold"),
        axis.text.x=element_text(size=7,angle=20,hjust=1),
        panel.grid.major.x=element_blank())

# ── Panel D: Per-species bars ─────────────────────────────────────────────────
sp_df <- gt_sp %>% rename(ground_truth=fraction)
for (res in results)
  sp_df <- left_join(sp_df, data.frame(taxon=res$det_names, fraction=res$det_vec[res$det_names],
                                        stringsAsFactors=FALSE) %>%
                       setNames(c("taxon", res$label)), by="taxon")
sp_long <- sp_df %>%
  pivot_longer(-taxon, names_to="source", values_to="abundance") %>%
  mutate(abundance=ifelse(is.na(abundance),0,abundance)*100,
         source=factor(source, levels=c("ground_truth",labels)),
         taxon=reorder(taxon, ifelse(source=="ground_truth",abundance,0), max))
bar_pal <- c("ground_truth"="#9E9E9E", pal)
pD <- ggplot(sp_long,aes(x=abundance,y=taxon,fill=source)) +
  geom_col(position=position_dodge(width=0.75),width=0.7) +
  scale_fill_manual(values=bar_pal,
                    labels=c("Ground Truth",labels)) +
  scale_x_continuous(expand=c(0,0)) +
  labs(title="D  Per-species Abundance — Ground Truth vs STAMINA-BIOME",
       x="Relative Abundance (%)",y=NULL,fill=NULL) +
  theme_minimal(base_size=9) +
  theme(plot.title=element_text(size=8,face="bold"),
        axis.text.y=element_text(size=7,face="italic"),
        legend.position="bottom",legend.text=element_text(size=7))

# ── Panel E: Scatter ──────────────────────────────────────────────────────────
scat_list <- lapply(seq_along(results), function(i) {
  res <- results[[i]]
  matched <- intersect(true_names, res$det_names)
  if (length(matched)==0) return(NULL)
  data.frame(ground_truth=sapply(matched,function(s)gt_vec[s])*100,
             detected=sapply(matched,function(s)res$det_vec[s])*100,
             db=res$label, stringsAsFactors=FALSE)
})
scat_df <- do.call(rbind, Filter(Negate(is.null), scat_list)) %>%
  mutate(db=factor(db,levels=labels))
xy_max <- max(scat_df$ground_truth, scat_df$detected)*1.1
r_labels <- sapply(results, function(res)
  if(!is.na(res$r)) sprintf("%s: r=%.4f", res$label, res$r) else sprintf("%s: r=N/A", res$label))
pE <- ggplot(scat_df,aes(x=ground_truth,y=detected,colour=db)) +
  geom_abline(slope=1,intercept=0,linetype="dashed",colour="grey60") +
  geom_point(size=2,alpha=0.85) +
  scale_colour_manual(values=pal, labels=r_labels) +
  scale_x_continuous(limits=c(0,xy_max),expand=c(0,0)) +
  scale_y_continuous(limits=c(0,xy_max),expand=c(0,0)) +
  labs(title="E  Ground Truth vs. Detected Abundance (Scatter)",
       x="Ground Truth (%)",y="Detected (%)",colour=NULL) +
  theme_minimal(base_size=9) +
  theme(plot.title=element_text(size=8,face="bold"),
        legend.position="bottom",legend.text=element_text(size=6.5),
        aspect.ratio=1)

# ── Panel F: Stats table ──────────────────────────────────────────────────────
fmt <- function(x) ifelse(is.na(x),"—",as.character(x))
stats_rows <- data.frame(
  Metric = c("Database","Bracken readlen","Recovery (%)","False Positives",
             "MAE (%)","Pearson r","p-value","Precision","Recall","F1-score"),
  stringsAsFactors=FALSE
)
for (res in results) {
  col <- c(res$label,"1500 bp",paste0(res$recovery,"%"),as.character(res$n_fp),
           paste0(res$mae_pct,"%"),fmt(res$r),fmt(res$pval),
           fmt(res$prec),fmt(res$rec),fmt(res$f1))
  stats_rows[[res$label]] <- col
}
col_fill <- c("white", pal)
pF <- tableGrob(stats_rows, rows=NULL,
  theme=ttheme_minimal(
    core=list(fg_params=list(fontsize=7.5),
              bg_params=list(fill=c("white","#ECEFF1"), col="grey80")),
    colhead=list(fg_params=list(fontsize=7.5,fontface="bold",col="white"),
                 bg_params=list(fill=c("#455A64", pal[1:n_db]), col="grey80"))
  ))

# ── Assemble ──────────────────────────────────────────────────────────────────
title_grob <- textGrob(
  sprintf("STAMINA-BIOME %s Metagenome Validation: Database Progression and Abundance Accuracy", site$full),
  gp=gpar(fontsize=13,fontface="bold"))
sub_grob <- textGrob(
  sprintf("CAMISIM NanoSim3 simulation — %s mock metagenome | %d true species | conf=best-fit, mhg=2", site$full, n_true),
  gp=gpar(fontsize=8,col="grey40"))

top_row    <- arrangeGrob(pA,pB,pC,ncol=3)
mid_row    <- arrangeGrob(pD,pE,ncol=2,widths=c(1.4,1))
full_fig   <- arrangeGrob(title_grob,sub_grob,top_row,mid_row,pF,
                          heights=c(0.05,0.03,0.26,0.36,0.30),ncol=1)
ggsave(OUT_PNG, full_fig, width=14, height=12, dpi=150, bg="white")
cat("Saved:", OUT_PNG, "\n")
