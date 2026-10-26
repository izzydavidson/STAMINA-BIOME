library(shiny)
library(jsonlite)

server <- function(input, output, session) {

  # ============================================================
  # RUN PIPELINE TAB
  # ============================================================

  rv <- reactiveValues(
    files = data.frame(
      id = character(),
      name = character(),
      datapath = character(),
      size_bytes = numeric(),
      stringsAsFactors = FALSE
    ),
    bound_delete_ids = character()
  )

  message_text <- reactiveVal("No messages yet.")

  id_counter <- reactiveVal(0)
  next_id <- function() {
    n <- id_counter() + 1
    id_counter(n)
    paste0("f", n)
  }

  add_uploads <- function(df) {
    if (is.null(df) || nrow(df) == 0) return()

    df$name <- as.character(df$name)
    df$datapath <- as.character(df$datapath)
    df$size <- as.numeric(df$size)

    new_rows <- data.frame(
      id = vapply(seq_len(nrow(df)), function(i) next_id(), character(1)),
      name = df$name,
      datapath = df$datapath,
      size_bytes = df$size,
      stringsAsFactors = FALSE
    )

    rv$files <- rbind(rv$files, new_rows)
  }

  register_delete_observer <- function(file_id) {
    if (file_id %in% rv$bound_delete_ids) return()

    rv$bound_delete_ids <- c(rv$bound_delete_ids, file_id)

    observeEvent(input[[paste0("del_", file_id)]], {
      rv$files <- rv$files[rv$files$id != file_id, , drop = FALSE]
    }, ignoreInit = TRUE)
  }

  observeEvent(input$sample_files, {
    add_uploads(input$sample_files)
  }, ignoreInit = TRUE)

  observeEvent(input$sample_dir, {
    add_uploads(input$sample_dir)
  }, ignoreInit = TRUE)

  output$upload_table <- renderUI({
    df <- rv$files

    if (is.null(df) || nrow(df) == 0) {
      return(div(class = "text-muted", "No files added yet."))
    }

    size_mb <- df$size_bytes / 1024^2
    size_display <- sprintf("%.1f MB", size_mb)

    lapply(df$id, register_delete_observer)

    rows <- lapply(seq_len(nrow(df)), function(i) {
      fid <- df$id[i]
      tags$tr(
        tags$td(df$name[i]),
        tags$td(size_display[i]),
        tags$td(
          actionButton(
            inputId = paste0("del_", fid),
            label = NULL,
            icon = icon("trash"),
            class = "btn btn-outline-danger btn-sm"
          )
        )
      )
    })

    tags$table(
      class = "table table-sm align-middle",
      tags$thead(
        tags$tr(
          tags$th("NAME"),
          tags$th("SIZE"),
          tags$th("")
        )
      ),
      tags$tbody(rows)
    )
  })

  output$upload_messages <- renderText({
    message_text()
  })

  observeEvent(input$validate_uploads, {
    df <- rv$files

    if (is.null(df) || nrow(df) == 0) {
      message_text("No files uploaded yet.")
      return()
    }

    allowed_ext <- c(
      "fastq", "fq", "gz",
      "fast5",
      "tsv", "csv", "txt",
      "json", "yaml", "yml"
    )

    ext <- tolower(sub(".*\\.", "", df$name))

    is_ok <- ext %in% allowed_ext |
      grepl("\\.fastq\\.gz$|\\.fq\\.gz$", tolower(df$name)) |
      grepl("\\.fastq$|\\.fq$|\\.fast5$", tolower(df$name))

    bad_files <- df$name[!is_ok]

    total_bytes <- sum(as.numeric(df$size_bytes), na.rm = TRUE)
    total_mb <- total_bytes / 1024^2

    msg <- c(
      paste0("Run label: ", ifelse(nzchar(input$run_label), input$run_label, "(none)")),
      paste0("Files uploaded: ", nrow(df)),
      paste0("Total size: ", sprintf("%.1f MB", total_mb))
    )

    if (length(bad_files) > 0) {
      msg <- c(
        msg, "",
        "Potentially unsupported files detected:",
        paste0(" - ", bad_files)
      )
    } else {
      msg <- c(msg, "", "All uploaded files look compatible with the current rules.")
    }

    message_text(paste(msg, collapse = "\n"))
  })

  observeEvent(input$run_pipeline, {
    script_path <- "./script.sh"

    if (!file.exists(script_path)) {
      message_text("script.sh was not found in the app directory.")
      return()
    }

    out <- tryCatch(
      system2("bash", script_path, stdout = TRUE, stderr = TRUE),
      error = function(e) paste("Error running script:", conditionMessage(e))
    )

    if (length(out) == 0) {
      message_text("Script ran, but produced no output.")
    } else {
      message_text(paste(out, collapse = "\n"))
    }
  })

  # ============================================================
  # COMPARE RUNS TAB
  # ============================================================

  compare_rv <- reactiveValues(
    available_runs = list(),
    compare_result = NULL,
    compare_complete = FALSE,
    compare_status = ""
  )

  # Scan for available runs
  scan_runs <- function() {
    outputs_dir <- file.path(getwd(), "data", "outputs")
    if (!dir.exists(outputs_dir)) {
      return(list())
    }

    runs <- list()
    run_dirs <- list.dirs(outputs_dir, recursive = FALSE, full.names = TRUE)

    for (run_dir in run_dirs) {
      run_name <- basename(run_dir)
      # Skip compare output directories
      if (grepl("^compare_", run_name)) next

      # Look for outputs.json in common locations
      outputs_json_paths <- c(
        file.path(run_dir, "outputs.json"),
        file.path(run_dir, "sr_amp", "outputs.json"),
        file.path(run_dir, "sr_meta", "outputs.json"),
        file.path(run_dir, "lr_amp", "outputs.json"),
        file.path(run_dir, "lr_meta", "outputs.json")
      )

      for (outputs_path in outputs_json_paths) {
        if (file.exists(outputs_path)) {
          tryCatch({
            outputs <- fromJSON(outputs_path)
            pipeline <- outputs$pipeline_id %||% outputs$module_name %||% "unknown"
            run_id <- outputs$run_id %||% run_name

            runs[[run_name]] <- list(
              run_id = run_id,
              pipeline = pipeline,
              path = run_dir,
              outputs_path = outputs_path
            )
            break
          }, error = function(e) {
            # Skip invalid JSON
          })
        }
      }
    }

    return(runs)
  }

  # Initialize run list
  observe({
    compare_rv$available_runs <- scan_runs()
  })

  # Refresh runs on button click
  observeEvent(input$refresh_runs, {
    compare_rv$available_runs <- scan_runs()
  })

  # Update checkbox choices when runs change
  observe({
    runs <- compare_rv$available_runs
    if (length(runs) == 0) {
      choices <- c("No runs found" = "")
    } else {
      choices <- setNames(
        names(runs),
        sapply(names(runs), function(n) {
          r <- runs[[n]]
          paste0(r$run_id, " (", r$pipeline, ")")
        })
      )
    }
    updateCheckboxGroupInput(session, "compare_runs", choices = choices)
  })

  # Run comparison
  observeEvent(input$run_compare, {
    selected_runs <- input$compare_runs
    if (is.null(selected_runs) || length(selected_runs) < 2) {
      compare_rv$compare_status <- "Please select at least 2 runs to compare."
      return()
    }

    # Get run paths
    run_paths <- sapply(selected_runs, function(n) {
      compare_rv$available_runs[[n]]$path
    })

    # Create comparison name
    compare_name <- paste0("compare_ui_", format(Sys.time(), "%Y%m%d_%H%M%S"))

    compare_rv$compare_status <- "Running comparison..."
    compare_rv$compare_complete <- FALSE

    # Build Python command
    python_script <- sprintf('
import sys
sys.path.insert(0, "compare/src")
from compare import CompareConfig, run_compare

config = CompareConfig(
    run_paths=%s,
    rank="%s",
    norm="%s",
    top_n=%d,
    outdir="data/outputs",
    name="%s",
    verbose=True,
)

exit_code = run_compare(config)
sys.exit(exit_code)
',
      paste0("[", paste0('"', run_paths, '"', collapse = ", "), "]"),
      input$compare_rank,
      input$compare_norm,
      input$compare_top_n,
      compare_name
    )

    # Run Python
    result <- tryCatch({
      output <- system2("python3", c("-c", shQuote(python_script)),
                        stdout = TRUE, stderr = TRUE)
      exit_code <- attr(output, "status") %||% 0
      list(success = exit_code == 0, output = output, name = compare_name)
    }, error = function(e) {
      list(success = FALSE, output = as.character(e), name = compare_name)
    })

    if (result$success) {
      compare_rv$compare_result <- result
      compare_rv$compare_complete <- TRUE
      compare_rv$compare_status <- paste0("Comparison complete: ", compare_name)
    } else {
      compare_rv$compare_complete <- FALSE
      compare_rv$compare_status <- paste0("Comparison failed:\n", paste(result$output, collapse = "\n"))
    }
  })

  # Output: compare complete flag
  output$compare_complete <- reactive({
    compare_rv$compare_complete
  })
  outputOptions(output, "compare_complete", suspendWhenHidden = FALSE)

  # Output: compare status
  output$compare_status <- renderUI({
    status <- compare_rv$compare_status
    if (nzchar(status)) {
      if (compare_rv$compare_complete) {
        div(class = "alert alert-success", status)
      } else if (grepl("Running", status)) {
        div(class = "alert alert-info", status)
      } else if (grepl("Please select|failed", status)) {
        div(class = "alert alert-warning", status)
      } else {
        div(class = "alert alert-secondary", status)
      }
    }
  })

  # Output: summary table
  output$compare_summary_table <- renderTable({
    if (!compare_rv$compare_complete || is.null(compare_rv$compare_result)) return(NULL)

    compare_name <- compare_rv$compare_result$name
    outputs_path <- file.path("data", "outputs", compare_name, "compare", "outputs.json")

    if (!file.exists(outputs_path)) return(data.frame(Message = "Results not found"))

    outputs <- fromJSON(outputs_path)
    metrics <- outputs$summary_metrics

    if (is.null(metrics)) return(data.frame(Message = "No metrics available"))

    data.frame(
      Metric = c("Jaccard Mean", "Sorensen Mean", "Bray-Curtis Similarity", "Total Taxa"),
      Value = c(
        round(metrics$jaccard_mean %||% 0, 4),
        round(metrics$sorensen_mean %||% 0, 4),
        round(metrics$bray_curtis_similarity_mean %||% 0, 4),
        as.character(metrics$total_taxa %||% 0)
      )
    )
  })

  # Output: harmonisation details
  output$compare_harmonisation <- renderText({
    if (!compare_rv$compare_complete || is.null(compare_rv$compare_result)) return("")

    compare_name <- compare_rv$compare_result$name
    outputs_path <- file.path("data", "outputs", compare_name, "compare", "outputs.json")

    if (!file.exists(outputs_path)) return("Results not found")

    outputs <- fromJSON(outputs_path)
    summary <- outputs$harmonisation_summary

    paste0(
      "Runs compared: ", paste(outputs$runs_compared, collapse = ", "), "\n",
      "Samples: ", summary$n_samples %||% "?", "\n",
      "Taxa: ", summary$n_taxa %||% "?", "\n",
      "Rank: ", summary$rank %||% "?", "\n",
      "Normalisation: ", summary$norm %||% "?"
    )
  })

  # Output: abundance table
  output$compare_abundance_table <- renderTable({
    if (!compare_rv$compare_complete || is.null(compare_rv$compare_result)) return(NULL)

    compare_name <- compare_rv$compare_result$name
    abundance_path <- file.path("data", "outputs", compare_name, "compare", "tables", "aligned_abundance.tsv")

    if (!file.exists(abundance_path)) return(data.frame(Message = "Abundance table not found"))

    df <- tryCatch({
      read.delim(abundance_path, row.names = 1, check.names = FALSE)
    }, error = function(e) {
      data.frame(Message = paste("Error reading file:", e$message))
    })

    # Show first 10 rows and 6 columns
    if (nrow(df) > 10) df <- df[1:10, , drop = FALSE]
    if (ncol(df) > 6) df <- df[, 1:6, drop = FALSE]

    df
  }, rownames = TRUE)

  # Output: download abundance
  output$download_abundance <- downloadHandler(
    filename = function() {
      paste0("aligned_abundance_", Sys.Date(), ".tsv")
    },
    content = function(file) {
      if (!compare_rv$compare_complete || is.null(compare_rv$compare_result)) return()

      compare_name <- compare_rv$compare_result$name
      abundance_path <- file.path("data", "outputs", compare_name, "compare", "tables", "aligned_abundance.tsv")

      if (file.exists(abundance_path)) {
        file.copy(abundance_path, file)
      }
    }
  )

  # Output: report link
  output$compare_report_link <- renderUI({
    if (!compare_rv$compare_complete || is.null(compare_rv$compare_result)) return(NULL)

    compare_name <- compare_rv$compare_result$name
    report_path <- file.path("data", "outputs", compare_name, "compare", "report", "index.html")

    if (file.exists(report_path)) {
      tagList(
        p("An HTML report has been generated."),
        tags$a(
          href = report_path,
          target = "_blank",
          class = "btn btn-outline-primary",
          "Open Report in New Tab"
        ),
        p(class = "mt-2 text-muted small",
          paste("Report location:", report_path))
      )
    } else {
      p("Report not found.")
    }
  })
}

# Helper for NULL coalescing
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
