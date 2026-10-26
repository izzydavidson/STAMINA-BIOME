compare_server <- function(id, shared) {
  moduleServer(id, function(input, output, session) {

    # ── Helpers ──────────────────────────────────────────────────────────────

    `%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

    # ── Native OS file pickers via osascript ─────────────────────────────────

    observeEvent(input$path_a_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "path_a", value = path)
    })

    observeEvent(input$path_b_browse, {
      path <- suppressWarnings(trimws(system("osascript -e 'POSIX path of (choose file)'", intern = TRUE)))
      if (length(path) > 0 && nchar(path) > 0) updateTextInput(session, "path_b", value = path)
    })


    # Detect whether a run directory has completed
    get_run_status <- function(run_dir) {
      logs_dir <- file.path(run_dir, "logs")
      if (!dir.exists(logs_dir)) return("Pending")
      log_files <- list.files(logs_dir, pattern = "\\.log$", full.names = TRUE)
      if (length(log_files) == 0) return("Pending")
      for (lf in log_files) {
        if (!file.exists(lf) || file.info(lf)$size == 0) next
        txt <- tryCatch(
          paste(readLines(lf, warn = FALSE), collapse = "\n"),
          error = function(e) ""
        )
        if (grepl("CONTAINER FAILED|ERROR: Module failed|Pipeline failed", txt)) return("Failed")
        # Accept any exit_code: 0 line OR legacy completion strings
        if (grepl("Pipeline completed successfully|Pipeline finished|To retry:|exit_code: 0", txt)) return("Completed")
        if (nchar(txt) > 0) return("In Progress")
      }
      "Pending"
    }

    # Search a run directory for the best species/genus tidy CSV
    find_tidy_csv <- function(run_dir, rank = "species") {
      pattern <- paste0(rank, "_tidy\\.csv$")
      all_csv <- list.files(run_dir, pattern = pattern, recursive = TRUE, full.names = TRUE)
      if (length(all_csv) == 0) return(NULL)
      # Prefer paths under a "final" directory
      final_csv <- grep("/final/|/final_results/", all_csv, value = TRUE)
      if (length(final_csv) > 0) all_csv <- final_csv
      # Prefer explicit emu_* or kraken_* prefixed files
      typed_csv <- grep("/(emu_|kraken_)", all_csv, value = TRUE)
      if (length(typed_csv) > 0) all_csv <- typed_csv
      all_csv[1]
    }

    # Parse a tidy CSV (Emu or Kraken format) → data.frame(sample_id, taxon, rel_abundance)
    parse_tidy_csv <- function(path, rank = "species") {
      if (is.null(path) || !file.exists(path)) return(NULL)
      df <- tryCatch(read.csv(path, stringsAsFactors = FALSE), error = function(e) NULL)
      if (is.null(df) || nrow(df) == 0) return(NULL)
      if (!"sample_id" %in% colnames(df)) {
        cat("[compare] Missing sample_id column in:", path, "\n")
        return(NULL)
      }

      # Find taxon column: try requested rank, then alternatives
      taxon_col <- NULL
      for (col in c(rank, "species", "genus", "taxon", "name")) {
        if (col %in% colnames(df)) { taxon_col <- col; break }
      }
      if (is.null(taxon_col)) {
        cat("[compare] No taxon column in:", path, "— columns:", paste(colnames(df), collapse = ", "), "\n")
        return(NULL)
      }

      # Find abundance column
      abund_col <- NULL
      for (col in c("abundance", "fraction", "reads", "count")) {
        if (col %in% colnames(df)) { abund_col <- col; break }
      }
      if (is.null(abund_col)) {
        cat("[compare] No abundance column in:", path, "\n")
        return(NULL)
      }

      result <- data.frame(
        sample_id     = as.character(df$sample_id),
        taxon         = as.character(df[[taxon_col]]),
        rel_abundance = suppressWarnings(as.numeric(df[[abund_col]])),
        stringsAsFactors = FALSE
      )

      # Raw read counts → normalize to relative abundance per sample
      if (abund_col %in% c("reads", "count")) {
        result <- do.call(rbind, lapply(split(result, result$sample_id), function(s) {
          tot <- sum(s$rel_abundance, na.rm = TRUE)
          if (tot > 0) s$rel_abundance <- s$rel_abundance / tot
          s
        }))
      }

      # Remove empty / NA rows
      result <- result[
        !is.na(result$taxon) & nzchar(trimws(result$taxon)) &
        !is.na(result$rel_abundance) & result$rel_abundance > 0, ]

      if (nrow(result) == 0) return(NULL)
      result
    }

    # Aggregate a parsed df to mean relative abundance per taxon across all samples
    agg_to_profile <- function(df) {
      if (is.null(df) || nrow(df) == 0) return(NULL)
      tapply(df$rel_abundance, df$taxon, mean, na.rm = TRUE)
    }

    # Alpha diversity per sample: Shannon, richness, Simpson, Pielou evenness
    compute_alpha <- function(df) {
      if (is.null(df) || nrow(df) == 0) return(NULL)
      do.call(rbind, lapply(split(df, df$sample_id), function(s) {
        p <- s$rel_abundance[!is.na(s$rel_abundance) & s$rel_abundance > 0]
        tot <- sum(p)
        if (tot > 0) p <- p / tot
        richness <- length(p)
        shannon  <- if (richness > 0) round(-sum(p * log(p)), 3) else 0
        simpson  <- if (richness > 0) round(1 - sum(p^2), 3) else 0
        evenness <- if (richness > 1) round(shannon / log(richness), 3) else NA_real_
        data.frame(
          sample_id = s$sample_id[1],
          richness  = richness,
          shannon   = shannon,
          simpson   = simpson,
          evenness  = evenness,
          stringsAsFactors = FALSE
        )
      }))
    }

    # Bray-Curtis dissimilarity matrix from a sample × taxon matrix (rows normalised)
    bray_curtis_matrix <- function(mat) {
      n <- nrow(mat)
      bc <- matrix(0.0, n, n, dimnames = list(rownames(mat), rownames(mat)))
      for (i in seq_len(n - 1)) {
        for (j in (i + 1):n) {
          denom <- sum(mat[i, ] + mat[j, ])
          val <- if (denom > 0) sum(abs(mat[i, ] - mat[j, ])) / denom else 0
          bc[i, j] <- bc[j, i] <- val
        }
      }
      bc
    }

    # ── Run discovery ─────────────────────────────────────────────────────────

    available_runs <- reactive({
      outputs_dir <- file.path(dirname(getwd()), "outputs")
      if (!dir.exists(outputs_dir)) return(c("No completed runs found" = ""))
      run_ids <- list.dirs(outputs_dir, recursive = FALSE, full.names = FALSE)
      # Exclude compare output dirs
      run_ids <- run_ids[!grepl("^compare_[0-9]", run_ids)]
      if (length(run_ids) == 0) return(c("No completed runs found" = ""))
      # Use outputs.json presence as a fast "completed" check — avoids reading log files for all runs
      completed <- Filter(
        function(r) file.exists(file.path(outputs_dir, r, "outputs.json")),
        run_ids
      )
      if (length(completed) > 0) setNames(completed, completed) else c("No completed runs found" = "")
    })

    observe({
      runs <- available_runs()
      updateSelectInput(session, "run1", choices = runs)
      updateSelectInput(session, "run2", choices = runs)
    })

    # ── Core comparison reactive ───────────────────────────────────────────────

    comparison_data <- reactiveVal(NULL)

    observeEvent(input$compare_btn, {
      rank <- input$rank %||% "species"

      if (input$input_mode == "csv") {
        # ── CSV upload mode ──
        path_a <- if (nzchar(trimws(input$path_a %||% ""))) trimws(input$path_a) else NULL
        path_b <- if (nzchar(trimws(input$path_b %||% ""))) trimws(input$path_b) else NULL

        if (is.null(path_a) || is.null(path_b)) {
          showNotification("Please provide both CSV files (Browse or type path).", type = "warning")
          return()
        }
        label_a  <- if (nzchar(trimws(input$label_a %||% ""))) trimws(input$label_a) else "Run A"
        label_b  <- if (nzchar(trimws(input$label_b %||% ""))) trimws(input$label_b) else "Run B"
        source_a <- basename(path_a)
        source_b <- basename(path_b)

      } else {
        # ── Run selection mode ──
        if (is.null(input$run1) || input$run1 == "" ||
            is.null(input$run2) || input$run2 == "") {
          showNotification("Please select two completed runs.", type = "warning")
          return()
        }
        if (input$run1 == input$run2) {
          showNotification("Please select two different runs.", type = "warning")
          return()
        }
        outputs_dir <- file.path(dirname(getwd()), "outputs")
        path_a      <- find_tidy_csv(file.path(outputs_dir, input$run1), rank)
        path_b      <- find_tidy_csv(file.path(outputs_dir, input$run2), rank)
        label_a     <- input$run1
        label_b     <- input$run2
        source_a    <- if (!is.null(path_a)) basename(path_a) else "not found"
        source_b    <- if (!is.null(path_b)) basename(path_b) else "not found"

        if (is.null(path_a)) {
          showNotification(
            paste("No", rank, "tidy CSV found in run:", input$run1),
            type = "error"
          )
          return()
        }
        if (is.null(path_b)) {
          showNotification(
            paste("No", rank, "tidy CSV found in run:", input$run2),
            type = "error"
          )
          return()
        }
      }

      withProgress(message = "Comparing...", value = 0.3, {
        df_a <- parse_tidy_csv(path_a, rank)
        df_b <- parse_tidy_csv(path_b, rank)
      })

      if (is.null(df_a) || nrow(df_a) == 0) {
        showNotification(
          paste("Could not parse data from", label_a, "— check that the file contains sample_id and", rank, "columns."),
          type = "error"
        )
        return()
      }
      if (is.null(df_b) || nrow(df_b) == 0) {
        showNotification(
          paste("Could not parse data from", label_b, "— check that the file contains sample_id and", rank, "columns."),
          type = "error"
        )
        return()
      }

      comparison_data(list(
        df_a     = df_a,
        df_b     = df_b,
        label_a  = label_a,
        label_b  = label_b,
        source_a = source_a,
        source_b = source_b,
        rank     = rank
      ))

      showNotification("Comparison complete.", type = "message", duration = 3)
    })

    output$has_results <- reactive({ !is.null(comparison_data()) })
    outputOptions(output, "has_results", suspendWhenHidden = FALSE)

    # ── Result header ─────────────────────────────────────────────────────────

    output$result_header <- renderUI({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)
      n_a <- length(unique(cd$df_a$sample_id))
      n_b <- length(unique(cd$df_b$sample_id))
      div(
        class = "row mb-2",
        div(class = "col-md-6",
          div(class = "alert alert-success", style = "font-size: 0.875rem; margin-bottom: 0;",
            tags$strong(cd$label_a), " — ",
            n_a, " sample(s), ",
            length(unique(cd$df_a$taxon)), " taxa"
          )
        ),
        div(class = "col-md-6",
          div(class = "alert alert-success", style = "font-size: 0.875rem; margin-bottom: 0;",
            tags$strong(cd$label_b), " — ",
            n_b, " sample(s), ",
            length(unique(cd$df_b$taxon)), " taxa"
          )
        )
      )
    })

    # ── Tab 1: Relative abundance ─────────────────────────────────────────────

    output$abundance_plot <- renderPlot({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)

      prof_a <- agg_to_profile(cd$df_a)
      prof_b <- agg_to_profile(cd$df_b)
      all_taxa <- union(names(prof_a), names(prof_b))

      va <- sapply(all_taxa, function(t) if (t %in% names(prof_a)) prof_a[[t]] else 0)
      vb <- sapply(all_taxa, function(t) if (t %in% names(prof_b)) prof_b[[t]] else 0)

      # Top 15 by combined mean abundance
      top_idx   <- head(order(-(va + vb)), 15)
      top_taxa  <- all_taxa[top_idx]
      va_top    <- va[top_idx]
      vb_top    <- vb[top_idx]

      mat <- rbind(va_top, vb_top)
      rownames(mat) <- c(cd$label_a, cd$label_b)
      colnames(mat) <- top_taxa

      rank_title <- paste0(toupper(substring(cd$rank, 1, 1)), substring(cd$rank, 2))

      par(mar = c(11, 5, 3, 1))
      barplot(
        mat,
        beside    = TRUE,
        col       = c("#4E79A7", "#F28E2B"),
        las       = 2,
        cex.names = 0.68,
        ylab      = "Mean Relative Abundance",
        main      = paste("Top", length(top_taxa), rank_title, "— Relative Abundance Comparison"),
        legend.text  = rownames(mat),
        args.legend  = list(x = "topright", bty = "n", cex = 0.9)
      )
    })

    output$abundance_table <- renderTable({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)

      prof_a   <- agg_to_profile(cd$df_a)
      prof_b   <- agg_to_profile(cd$df_b)
      all_taxa <- union(names(prof_a), names(prof_b))

      va <- sapply(all_taxa, function(t) if (t %in% names(prof_a)) round(prof_a[[t]], 4) else 0)
      vb <- sapply(all_taxa, function(t) if (t %in% names(prof_b)) round(prof_b[[t]], 4) else 0)

      df <- data.frame(
        Taxon = all_taxa,
        A     = va,
        B     = vb,
        stringsAsFactors = FALSE
      )
      colnames(df)[2] <- cd$label_a
      colnames(df)[3] <- cd$label_b

      df <- df[order(-(va + vb)), ]
      head(df, 30)
    }, striped = TRUE, hover = TRUE, spacing = "s")

    # ── Tab 2: Alpha diversity ────────────────────────────────────────────────

    output$alpha_table <- renderTable({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)

      alpha_a <- compute_alpha(cd$df_a)
      alpha_b <- compute_alpha(cd$df_b)

      if (!is.null(alpha_a)) alpha_a$Run <- cd$label_a
      if (!is.null(alpha_b)) alpha_b$Run <- cd$label_b

      combined <- rbind(alpha_a, alpha_b)
      combined[, c("Run", "sample_id", "richness", "shannon", "simpson", "evenness")]
    }, striped = TRUE, hover = TRUE, spacing = "s")

    # ── Tab 3: Beta diversity ─────────────────────────────────────────────────

    output$beta_table <- renderTable({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)

      # Tag rows with run label so samples across both runs can be identified
      df_a      <- cd$df_a; df_a$uid <- paste0(cd$label_a, " :: ", df_a$sample_id)
      df_b      <- cd$df_b; df_b$uid <- paste0(cd$label_b, " :: ", df_b$sample_id)
      combined  <- rbind(df_a, df_b)

      all_taxa <- unique(combined$taxon)
      uids     <- unique(combined$uid)

      if (length(uids) < 2) {
        return(data.frame(Note = "Need at least 2 samples total for beta diversity."))
      }

      # Build sample × taxon matrix
      mat <- matrix(0.0, nrow = length(uids), ncol = length(all_taxa),
                    dimnames = list(uids, all_taxa))
      for (i in seq_len(nrow(combined))) {
        uid <- combined$uid[i]
        tx  <- combined$taxon[i]
        mat[uid, tx] <- mat[uid, tx] + combined$rel_abundance[i]
      }
      # Row-normalise
      rs  <- rowSums(mat)
      mat <- mat / ifelse(rs > 0, rs, 1)

      bc     <- bray_curtis_matrix(mat)
      bc_df  <- as.data.frame(round(bc, 4))
      bc_df  <- cbind(Sample = rownames(bc_df), bc_df)
      bc_df
    }, striped = TRUE, hover = TRUE, spacing = "s")

    # ── Tab 4: Shared / unique taxa ───────────────────────────────────────────

    output$shared_summary <- renderText({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)

      taxa_a <- unique(cd$df_a$taxon[cd$df_a$rel_abundance > 0])
      taxa_b <- unique(cd$df_b$taxon[cd$df_b$rel_abundance > 0])

      shared <- intersect(taxa_a, taxa_b)
      only_a <- setdiff(taxa_a, taxa_b)
      only_b <- setdiff(taxa_b, taxa_a)

      sprintf(
        "%s: %d taxa | %s: %d taxa\nShared: %d | Only in %s: %d | Only in %s: %d",
        cd$label_a, length(taxa_a),
        cd$label_b, length(taxa_b),
        length(shared),
        cd$label_a, length(only_a),
        cd$label_b, length(only_b)
      )
    })

    output$shared_table <- renderTable({
      cd <- comparison_data()
      if (is.null(cd)) return(NULL)

      taxa_a <- unique(cd$df_a$taxon[cd$df_a$rel_abundance > 0])
      taxa_b <- unique(cd$df_b$taxon[cd$df_b$rel_abundance > 0])

      shared <- sort(intersect(taxa_a, taxa_b))
      only_a <- sort(setdiff(taxa_a, taxa_b))
      only_b <- sort(setdiff(taxa_b, taxa_a))

      max_len <- max(length(shared), length(only_a), length(only_b), 1L)
      pad     <- function(x, n) c(x, rep("", n - length(x)))

      df <- data.frame(
        `Shared taxa`  = pad(shared, max_len),
        `Only in A`    = pad(only_a, max_len),
        `Only in B`    = pad(only_b, max_len),
        check.names    = FALSE,
        stringsAsFactors = FALSE
      )
      colnames(df)[2] <- paste0("Only in ", cd$label_a)
      colnames(df)[3] <- paste0("Only in ", cd$label_b)
      df
    }, striped = TRUE, hover = TRUE, spacing = "s")

  })
}
