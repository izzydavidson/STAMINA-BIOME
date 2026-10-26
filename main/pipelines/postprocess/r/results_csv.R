#!/usr/bin/env Rscript

# =============================================================================
# STAMINA-BIOME R Postprocess: Results CSV (Tidy Table Output)
# Works with both sr_amp (QIIME2) and sr_meta (Kraken2) outputs
# Generates consistent tidy table format for downstream analysis
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
  stop("Usage: results_csv.R --outputs_json <path> --out_dir <dir> [--params_json <json>] [--module <name>]")
}

# Load outputs.json
outputs <- fromJSON(outputs_json)
params <- tryCatch(fromJSON(params_json), error = function(e) list())

`%||%` <- function(x, y) if (is.null(x)) y else x

# Apply barcode → sample name mapping from sample sheet (if provided)
apply_sample_map <- function(df, sample_col, params) {
  tsv <- params$sample_sheet %||% NULL
  if (is.null(tsv) || !nzchar(tsv) || !file.exists(tsv)) return(df)
  sheet <- tryCatch(
    read.delim(tsv, stringsAsFactors = FALSE, na.strings = ""),
    error = function(e) NULL
  )
  if (is.null(sheet) || !all(c("barcode", "sample_name") %in% colnames(sheet))) return(df)
  name_map <- setNames(sheet$sample_name, sheet$barcode)
  bc_key   <- sub(".*_(barcode[0-9]+)$", "\\1", df[[sample_col]])
  mapped   <- name_map[bc_key]
  df[[sample_col]] <- ifelse(!is.na(mapped) & nzchar(mapped), mapped, df[[sample_col]])
  df
}

cat("[results_csv] Module:", module_name, "\n")
cat("[results_csv] Output dir:", out_dir, "\n")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Collect all results into a structured format
results <- list(
  module = module_name,
  run_id = outputs$run_id,
  sample_id = outputs$sample_id,
  pipeline_id = outputs$pipeline_id,
  specimen = outputs$specimen,
  input_style = outputs$input_style
)

# Helper to safely get nested values
safe_get <- function(obj, ...) {
  tryCatch({
    val <- obj
    for (key in c(...)) {
      if (is.null(val) || !key %in% names(val)) return(NULL)
      val <- val[[key]]
    }
    return(val)
  }, error = function(e) NULL)
}

# ----- Process taxonomy data -----
taxa_data <- NULL

if (module_name %in% c("sr_meta", "lr_meta", "lr_amp") || is.null(module_name)) {
  postprocess_dir <- outputs$postprocess$dir
  if (!is.null(postprocess_dir)) {
    # Load both species and genus data
    species_tidy <- file.path(postprocess_dir, "kraken_species_tidy.csv")
    genus_tidy <- file.path(postprocess_dir, "kraken_genus_tidy.csv")

    if (file.exists(species_tidy)) {
      species_df <- read.csv(species_tidy, stringsAsFactors = FALSE)
      species_df$rank <- "species"
      species_df$taxon <- species_df$species
      species_df <- species_df[, c("sample_id", "taxid", "taxon", "rank", "reads", "fraction")]

      if (file.exists(genus_tidy)) {
        genus_df <- read.csv(genus_tidy, stringsAsFactors = FALSE)
        genus_df$rank <- "genus"
        genus_df$taxon <- genus_df$genus
        genus_df <- genus_df[, c("sample_id", "taxid", "taxon", "rank", "reads", "fraction")]

        taxa_data <- rbind(species_df, genus_df)
      } else {
        taxa_data <- species_df
      }
      cat("[results_csv] Loaded Kraken2 taxonomy data\n")
    }
  }
}

if (is.null(taxa_data) && (module_name == "sr_amp" || is.null(module_name))) {
  qiime2_exports <- outputs$qiime2_exports
  if (!is.null(qiime2_exports)) {
    table_tsv <- qiime2_exports$table_tsv
    taxonomy_tsv <- qiime2_exports$taxonomy_tsv

    if (!is.null(table_tsv) && file.exists(table_tsv) &&
        !is.null(taxonomy_tsv) && file.exists(taxonomy_tsv)) {
      cat("[results_csv] Using QIIME2 exports\n")

      lines <- readLines(table_tsv)
      header_idx <- which(grepl("^#OTU ID", lines))[1]
      if (!is.na(header_idx)) {
        table_df <- read.delim(text = paste(lines[header_idx:length(lines)], collapse = "\n"),
                              sep = "\t", stringsAsFactors = FALSE, check.names = FALSE)
        colnames(table_df)[1] <- "FeatureID"

        tax_df <- read.delim(taxonomy_tsv, stringsAsFactors = FALSE, check.names = FALSE)
        colnames(tax_df)[1] <- "FeatureID"

        # Parse taxonomy to extract ranks
        parse_taxonomy <- function(taxon) {
          if (is.na(taxon) || taxon == "") {
            return(list(kingdom = NA, phylum = NA, class = NA, order = NA, family = NA, genus = NA, species = NA))
          }
          parts <- strsplit(taxon, ";")[[1]]
          parts <- trimws(parts)

          result <- list(kingdom = NA, phylum = NA, class = NA, order = NA, family = NA, genus = NA, species = NA)
          rank_map <- list(
            k = "kingdom", p = "phylum", c = "class", o = "order", f = "family", g = "genus", s = "species",
            D_0 = "kingdom", D_1 = "phylum", D_2 = "class", D_3 = "order", D_4 = "family", D_5 = "genus", D_6 = "species"
          )

          for (p in parts) {
            for (prefix in names(rank_map)) {
              pattern <- paste0("^", prefix, "__")
              if (grepl(pattern, p)) {
                val <- sub(pattern, "", p)
                if (val != "" && !grepl("^unclassified", val, ignore.case = TRUE)) {
                  result[[rank_map[[prefix]]]] <- val
                }
                break
              }
            }
          }
          return(result)
        }

        sample_cols <- setdiff(colnames(table_df), "FeatureID")

        tidy_rows <- list()
        for (i in seq_len(nrow(table_df))) {
          fid <- table_df$FeatureID[i]
          tax_row <- tax_df[tax_df$FeatureID == fid, ]
          if (nrow(tax_row) == 0) next

          taxon_str <- tax_row$Taxon[1]
          parsed <- parse_taxonomy(taxon_str)

          for (s in sample_cols) {
            count <- as.numeric(table_df[i, s])
            if (!is.na(count) && count > 0) {
              tidy_rows[[length(tidy_rows) + 1]] <- data.frame(
                sample_id = s,
                feature_id = fid,
                taxon = taxon_str,
                kingdom = parsed$kingdom,
                phylum = parsed$phylum,
                class = parsed$class,
                order = parsed$order,
                family = parsed$family,
                genus = parsed$genus,
                species = parsed$species,
                count = count,
                stringsAsFactors = FALSE
              )
            }
          }
        }

        if (length(tidy_rows) > 0) {
          taxa_data <- do.call(rbind, tidy_rows)

          # Calculate relative abundance per sample
          totals <- aggregate(count ~ sample_id, data = taxa_data, FUN = sum)
          colnames(totals)[2] <- "total"
          taxa_data <- merge(taxa_data, totals, by = "sample_id")
          taxa_data$relative_abundance <- taxa_data$count / taxa_data$total
          taxa_data$total <- NULL

          cat("[results_csv] Loaded QIIME2 taxonomy data\n")
        }
      }
    }
  }
}

# Apply barcode → sample name mapping
if (!is.null(taxa_data) && nrow(taxa_data) > 0) {
  taxa_data <- apply_sample_map(taxa_data, "sample_id", params)
}

# Write taxonomy results
if (!is.null(taxa_data) && nrow(taxa_data) > 0) {
  taxa_out <- file.path(out_dir, "results.csv")
  write.csv(taxa_data, taxa_out, row.names = FALSE)
  cat("[results_csv] Wrote taxonomy results:", taxa_out, "\n")
}

# ----- Process alpha diversity (if available) -----
alpha_data <- NULL

if (module_name == "sr_amp" || is.null(module_name)) {
  alpha_tsvs <- safe_get(outputs, "qiime2_artifacts", "alpha_diversity_tsv")
  if (!is.null(alpha_tsvs)) {
    alpha_rows <- list()

    for (metric in c("shannon", "observed_features", "pielou_e")) {
      tsv_path <- alpha_tsvs[[metric]]
      if (!is.null(tsv_path) && file.exists(tsv_path)) {
        df <- read.delim(tsv_path, stringsAsFactors = FALSE, check.names = FALSE)
        if (nrow(df) > 0) {
          colnames(df)[1] <- "sample_id"
          colnames(df)[2] <- "value"
          df$metric <- metric
          alpha_rows[[metric]] <- df[, c("sample_id", "metric", "value")]
        }
      }
    }

    if (length(alpha_rows) > 0) {
      alpha_data <- do.call(rbind, alpha_rows)
    }
  }
}

if (!is.null(alpha_data) && nrow(alpha_data) > 0) {
  alpha_out <- file.path(out_dir, "alpha_diversity.csv")
  write.csv(alpha_data, alpha_out, row.names = FALSE)
  cat("[results_csv] Wrote alpha diversity results:", alpha_out, "\n")
}

# ----- Create summary statistics -----
summary_data <- data.frame(
  metric = character(),
  value = character(),
  stringsAsFactors = FALSE
)

add_summary <- function(metric, value) {
  # Handle NULL or empty values to avoid "arguments imply differing number of rows" error
  if (is.null(value) || length(value) == 0) value <- NA
  summary_data <<- rbind(summary_data, data.frame(metric = metric, value = as.character(value), stringsAsFactors = FALSE))
}

add_summary("module", module_name)
add_summary("run_id", results$run_id)
add_summary("sample_id", results$sample_id)
add_summary("pipeline_id", results$pipeline_id)
add_summary("input_style", results$input_style)

if (!is.null(taxa_data)) {
  add_summary("n_taxa", length(unique(taxa_data$taxon)))
  add_summary("n_samples", length(unique(taxa_data$sample_id)))

  if ("reads" %in% colnames(taxa_data)) {
    add_summary("total_reads", sum(taxa_data$reads, na.rm = TRUE))
  } else if ("count" %in% colnames(taxa_data)) {
    add_summary("total_counts", sum(taxa_data$count, na.rm = TRUE))
  }
}

if (!is.null(alpha_data)) {
  for (m in unique(alpha_data$metric)) {
    vals <- alpha_data$value[alpha_data$metric == m]
    add_summary(paste0("alpha_", m, "_mean"), round(mean(vals, na.rm = TRUE), 4))
  }
}

summary_out <- file.path(out_dir, "summary_stats.csv")
write.csv(summary_data, summary_out, row.names = FALSE)
cat("[results_csv] Wrote summary statistics:", summary_out, "\n")

# ----- Create run metadata JSON -----
metadata <- list(
  module = module_name,
  run_id = results$run_id,
  sample_id = results$sample_id,
  pipeline_id = results$pipeline_id,
  specimen = results$specimen,
  input_style = results$input_style,
  outputs_generated = list(
    results_csv = file.exists(file.path(out_dir, "results.csv")),
    alpha_diversity_csv = file.exists(file.path(out_dir, "alpha_diversity.csv")),
    summary_stats_csv = TRUE
  ),
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
)

metadata_out <- file.path(out_dir, "metadata.json")
write(toJSON(metadata, auto_unbox = TRUE, pretty = TRUE), metadata_out)
cat("[results_csv] Wrote metadata:", metadata_out, "\n")

cat("[results_csv] Complete\n")
