library(shiny)
library(bslib)

options(shiny.maxRequestSize = 5 * 1024^3) # 5GB upload limit

stamp_config_defaults <- list(
  input_type = "fastq",
  sample_type = "vaginal",
  run_id = "run_001",
  output_dir = "/path/to/output",
  prep_profile = "alt_fastq_prep",
  barcode_kit = "",
  min_qscore = 10,
  valencia_enabled = "auto",
  output_styles = c("stacked_bar", "raw_csv"),
  run_scope = "full",

  # NEW defaults (2x2 options live here)
  sequencing_approach = "shotgun",  # shotgun | amplicon
  read_technology = "long",         # long | short
  platform = "nanopore",            # nanopore | pacbio | illumina
  marker = "16S"                    # only used when amplicon
)

# Custom CSS
custom_css <- "
    .sidebar h4, .sidebar h5 {
      margin-bottom: 0.2rem !important;
    }
    .sidebar p {
      margin-bottom: 0.35rem !important;
    }
    .sidebar .control-label {
      margin-bottom: 0.15rem !important;
    }
    .sidebar .shiny-input-container {
      margin-bottom: 0.4rem !important;
    }
    .sidebar hr {
      margin-top: 0.35rem !important;
      margin-bottom: 0.45rem !important;
    }
    .stamp-inputs-block {
      margin-bottom: 0.2rem;
    }
    .stamp-hero {
      padding: 0.25rem 0 0.5rem 0;
    }
    .stamp-hero h1 {
      margin-bottom: 0.25rem;
    }
    .stamp-section-title {
      margin-top: 0.15rem;
    }
    .stamp-run-bar {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 0.5rem;
      padding: 0.25rem 0 0.5rem 0;
    }
    .stamp-run-bar .btn {
      min-width: 160px;
    }
    .stamp-subtle {
      color: rgba(255,255,255,0.75);
    }
    @media (max-width: 991px) {
      .stamp-run-bar {
        justify-content: flex-start;
      }
      .stamp-run-bar .btn {
        width: 100%;
      }
    }
    .compare-section {
      padding: 1rem;
    }
    .compare-run-card {
      border: 1px solid #dee2e6;
      border-radius: 0.5rem;
      padding: 1rem;
      margin-bottom: 0.5rem;
      background: #f8f9fa;
    }
    .compare-run-card.selected {
      border-color: #2D89C8;
      background: #e7f1f9;
    }
    .compare-results {
      margin-top: 1rem;
    }
"

# Run Pipeline tab content
run_tab <- nav_panel(
  title = "Run Pipeline",
  layout_sidebar(
    fill = FALSE,

    sidebar = sidebar(
      h4("Inputs"),
      p("Add files for a new run."),

      div(
        class = "stamp-inputs-block",

        fileInput(
          inputId = "sample_files",
          label = "Select files",
          multiple = TRUE,
          accept = c(
            ".fastq", ".fq", ".fastq.gz", ".fq.gz",
            ".fast5",
            ".tsv", ".csv", ".txt",
            ".json", ".yaml", ".yml"
          )
        ),

        fileInput(
          inputId = "sample_dir",
          label = "Select a folder (Chrome/Edge recommended)",
          multiple = TRUE,
          accept = c(
            ".fastq", ".fq", ".fastq.gz", ".fq.gz",
            ".fast5",
            ".tsv", ".csv", ".txt",
            ".json", ".yaml", ".yml"
          )
        )
      ),

      tags$script(HTML("
        (function() {
          function enableDir() {
            var el = document.getElementById('sample_dir');
            if (el) {
              el.setAttribute('webkitdirectory', '');
              el.setAttribute('directory', '');
              el.setAttribute('multiple', '');
            }
          }
          document.addEventListener('DOMContentLoaded', enableDir);
          setTimeout(enableDir, 250);
          setTimeout(enableDir, 1000);
        })();
      ")),

      hr(),

      h5("Run configuration"),
      p("Set analysis mode and preprocessing options for this run."),

      selectInput(
        inputId = "sequencing_approach",
        label = "Sequencing approach",
        choices = c(
          "Shotgun metagenomics" = "shotgun",
          "Amplicon sequencing" = "amplicon"
        ),
        selected = stamp_config_defaults$sequencing_approach
      ),

      selectInput(
        inputId = "input_type",
        label = "Input type",
        choices = c("fastq", "fast5"),
        selected = stamp_config_defaults$input_type
      ),

      selectInput(
        inputId = "sample_type",
        label = "Sample type",
        choices = c("skin", "oral", "gut", "vaginal"),
        selected = stamp_config_defaults$sample_type
      ),

      textInput(
        inputId = "run_label",
        label = "Run ID",
        value = stamp_config_defaults$run_id,
        placeholder = "e.g., run_001 or 2025-12-09_gut_batch1"
      ),

      textInput(
        inputId = "output_dir",
        label = "Output directory",
        value = stamp_config_defaults$output_dir,
        placeholder = "/path/to/output"
      ),

      selectInput(
        inputId = "run_scope",
        label = "Run scope",
        choices = c(
          "Run full pipeline and gather all results" = "full",
          "QC only (FastQC raw + post-processing)" = "qc_only"
        ),
        selected = stamp_config_defaults$run_scope
      ),

      hr(),

      h5("Preprocessing"),
      p("Adjust only if you need to override the preset behaviour."),

      selectInput(
        inputId = "prep_profile",
        label = "Prep profile",
        choices = c("dorado", "alt_fastq_prep"),
        selected = stamp_config_defaults$prep_profile
      ),

      textInput(
        inputId = "barcode_kit",
        label = "Barcode kit (optional)",
        value = stamp_config_defaults$barcode_kit,
        placeholder = "e.g., SQK-RBK114.24"
      ),

      numericInput(
        inputId = "min_qscore",
        label = "Minimum Q-score",
        value = stamp_config_defaults$min_qscore,
        min = 0,
        step = 1
      ),

      hr(),

      h5("Classification"),
      p("Vaginal CST classification can be enabled automatically when relevant."),

      selectInput(
        inputId = "valencia_enabled",
        label = "VALENCIA",
        choices = c("auto", "true", "false"),
        selected = stamp_config_defaults$valencia_enabled
      ),

      hr(),

      h5("Output style"),
      p("Choose one or more outputs to generate for this run."),

      selectInput(
        inputId = "output_styles",
        label = "Outputs",
        choices = c(
          "Heatmap" = "heatmap",
          "Stacked bar chart" = "stacked_bar",
          "Pie chart" = "pie_chart",
          "Raw data .csv file" = "raw_csv"
        ),
        selected = stamp_config_defaults$output_styles,
        multiple = TRUE
      ),

      width = 320
    ),

    div(
      class = "stamp-hero",
      h1("STAMINA-BIOME"),
      p(
        "STAMINA-BIOME – Standardised, Technology-Agnostic Framework for Microbiome Investigation and Analysis ",
        "is a lightweight interface for preparing microbial sequencing runs. ",
        "Upload sequencing inputs, choose your run configuration, review the files received, ",
        "then run your local workflow."
      )
    ),

    h4("Uploaded files", class = "stamp-section-title"),
    p(
      "Files are held in a temporary session location after upload. ",
      "Review names and sizes, remove anything incorrect, then run. ",
      "Sizes are shown in MB."
    ),

    uiOutput("upload_table"),

    div(
      class = "stamp-run-bar",
      actionButton("run_pipeline", "Run analysis", class = "btn-primary")
    ),

    hr(),

    h4("Validation messages", class = "stamp-section-title"),
    p("This panel displays messages emitted by the run script."),
    verbatimTextOutput("upload_messages")
  )
)

# Compare Runs tab content
compare_tab <- nav_panel(
  title = "Compare Runs",
  div(
    class = "compare-section",

    h2("Compare Analysis Runs"),
    p("Select two or more completed runs to compare their taxonomic profiles."),

    hr(),

    fluidRow(
      column(
        width = 4,
        h4("1. Select Runs"),
        p("Choose runs from the outputs directory to compare."),

        actionButton("refresh_runs", "Refresh Run List", class = "btn-secondary btn-sm mb-3"),

        checkboxGroupInput(
          inputId = "compare_runs",
          label = "Available Runs:",
          choices = c("Loading..." = ""),
          selected = NULL
        ),

        hr(),

        h4("2. Compare Options"),

        selectInput(
          inputId = "compare_rank",
          label = "Taxonomic Rank",
          choices = c("species", "genus", "family"),
          selected = "species"
        ),

        selectInput(
          inputId = "compare_norm",
          label = "Normalisation",
          choices = c("relative", "clr"),
          selected = "relative"
        ),

        numericInput(
          inputId = "compare_top_n",
          label = "Top N Taxa for Plots",
          value = 20,
          min = 5,
          max = 100
        ),

        hr(),

        actionButton("run_compare", "Run Comparison", class = "btn-primary"),

        div(class = "mt-3",
            uiOutput("compare_status"))
      ),

      column(
        width = 8,
        h4("Comparison Results"),

        conditionalPanel(
          condition = "output.compare_complete",

          navset_card_tab(
            nav_panel(
              "Summary",
              h5("Summary Metrics"),
              tableOutput("compare_summary_table"),
              hr(),
              h5("Harmonisation Details"),
              verbatimTextOutput("compare_harmonisation")
            ),
            nav_panel(
              "Tables",
              h5("Aligned Abundance Matrix"),
              p("First 10 rows shown. Use download button for full data."),
              tableOutput("compare_abundance_table"),
              downloadButton("download_abundance", "Download Full Table")
            ),
            nav_panel(
              "Report",
              h5("HTML Report"),
              uiOutput("compare_report_link")
            )
          )
        ),

        conditionalPanel(
          condition = "!output.compare_complete",
          div(
            class = "text-muted p-4 text-center",
            p("Select 2 or more runs and click 'Run Comparison' to see results.")
          )
        )
      )
    )
  )
)

# Main UI
ui <- page_navbar(
  title = "STAMINA-BIOME",
  theme = bs_theme(
    version = 5,
    primary = "#2D89C8"
  ),

  tags$head(tags$style(HTML(custom_css))),

  run_tab,
  compare_tab
)
