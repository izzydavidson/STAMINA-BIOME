# =============================================================================
# sample_order.R - shared sample ordering for the postprocess plots and tables
#
# Samples are shown in the order the user entered them in the GUI or the CLI
# sample sheet (barcode, sample_name[, site]); the sheet's row order is that
# order. Samples not in the sheet (or runs without a sheet) follow it in natural
# order, so sample2 comes before sample10. Site groups (mixed-site runs) are
# ordered by where their first sample appears.
#
# Sourced by stacked_bar.R, heatmap.R, piechart.R, results_csv.R, valencia.R
# and frontend/pipelines/postprocess/r/piechart.R.
# =============================================================================

# Natural sort key: digit runs zero-padded so "sample2" < "sample10"
sample_natural_key <- function(x) {
  k <- tolower(as.character(x))
  m <- gregexpr("[0-9]+", k)
  regmatches(k, m) <- lapply(regmatches(k, m), function(d) {
    paste0(strrep("0", pmax(0, 20 - nchar(d))), d)
  })
  k
}

# The sample sheet (data.frame in row order) from params$sample_sheet, or the
# STAMINA_SAMPLE_SHEET env var set by run_r_postprocess.sh; NULL if none
read_sample_order_sheet <- function(params = list()) {
  tsv <- NULL
  if (is.list(params) && !is.null(params$sample_sheet)) tsv <- as.character(params$sample_sheet)[1]
  if (is.null(tsv) || is.na(tsv) || !nzchar(tsv)) tsv <- Sys.getenv("STAMINA_SAMPLE_SHEET", "")
  if (!nzchar(tsv) || !file.exists(tsv)) return(NULL)
  sheet <- tryCatch(
    read.delim(tsv, stringsAsFactors = FALSE, na.strings = "", colClasses = "character"),
    error = function(e) NULL
  )
  if (is.null(sheet) || !"barcode" %in% colnames(sheet) || nrow(sheet) == 0) return(NULL)
  if (!"sample_name" %in% colnames(sheet)) sheet$sample_name <- NA_character_
  sheet
}

# sample_levels(ids, params): the unique sample IDs in display order.
# IDs may be the user's sample names, plain barcodes, or demux IDs ending in
# _barcodeNN; each sheet row matches any of these.
sample_levels <- function(ids, params = list()) {
  ids <- unique(as.character(ids[!is.na(ids)]))
  if (length(ids) == 0) return(character())
  ordered <- character()
  sheet <- read_sample_order_sheet(params)
  if (!is.null(sheet)) {
    id_barcode <- sub("^.*_(barcode[0-9]+)$", "\\1", ids)
    for (i in seq_len(nrow(sheet))) {
      bc <- trimws(sheet$barcode[i])
      nm <- trimws(sheet$sample_name[i])
      hit <- ids[(!is.na(nm) & nzchar(nm) & ids == nm) | ids == bc | id_barcode == bc]
      ordered <- c(ordered, hit)
    }
    ordered <- unique(ordered)
  }
  rest <- setdiff(ids, ordered)
  c(ordered, rest[order(sample_natural_key(rest))])
}

# group_levels(sample_ids, groups, sample_lv): group labels (e.g. sites) ordered
# by the position of their first sample in sample_lv
group_levels <- function(sample_ids, groups, sample_lv) {
  pos <- match(as.character(sample_ids), sample_lv)
  unique(as.character(groups)[order(pos)])
}

# order_rows_by_sample(df, col, params): df rows sorted by sample display order,
# keeping the existing row order within each sample
order_rows_by_sample <- function(df, col = "sample_id", params = list()) {
  if (is.null(df) || nrow(df) == 0 || !col %in% colnames(df)) return(df)
  lv <- sample_levels(df[[col]], params)
  df <- df[order(match(as.character(df[[col]]), lv), seq_len(nrow(df))), , drop = FALSE]
  rownames(df) <- NULL
  df
}
