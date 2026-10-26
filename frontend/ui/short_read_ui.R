short_read_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(
      class = "container-fluid p-4",

      div(
        class = "mb-4",
        h1("Short Read Sequencing"),
        p(class = "text-muted", "Illumina, Ion Torrent, BGI platforms")
      ),

      div(
        class = "row",

        div(
          class = "col-lg-8",

          div(
            class = "card mb-4",
            div(
              class = "card-body",
              h2(icon("file-text"), " Input Configuration"),
              div(
                class = "row",
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Technology Used"),
                  selectInput(ns("technology"), NULL,
                    choices = c("Illumina" = "illumina", "Ion Torrent" = "iontorrent", "BGI Platforms" = "bgi"),
                    selected = "illumina"
                  )
                ),
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Run Name/ID"),
                  textInput(ns("run_name"), NULL, value = "", placeholder = "e.g., SR_2026_001")
                ),
                div(
                  class = "col-md-12 mb-3",
                  tags$label(class = "form-label",
                    "Output Directory",
                    tags$span(class = "text-muted",
                      style = "font-size: 0.8rem; font-weight: 400;", " (Optional)")
                  ),
                  div(
                    class = "file-browse-group",
                    div(
                      class = "drop-zone",
                      div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                      actionButton(ns("extra_output_dir_browse"), "Browse",
                        class = "btn btn-outline-secondary"
                      )
                    ),
                    textInput(ns("extra_output_dir"), NULL,
                      placeholder = "/path/to/output  (e.g. /Users/you/Desktop)",
                      width = "100%"
                    )
                  ),
                  tags$small(class = "text-muted", "A copy of the run folder will be saved here after a successful run.")
                )
              ),

              hr(),
              h3(icon("upload"), " Input Files"),
              div(
                class = "mb-3",
                checkboxInput(ns("paired_end"), "Paired-End Reads", value = FALSE)
              ),
              conditionalPanel(
                condition = sprintf("!input['%s']", ns("paired_end")),
                div(
                  class = "mb-3",
                  tags$label(class = "form-label", "FASTQ File or Directory"),
                  div(
                    class = "file-browse-group",
                    div(
                      class = "drop-zone",
                      div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                      div(
                        class = "btn-group",
                        actionButton(ns("input_path_browse_file"), "File",
                          class = "btn btn-outline-secondary"
                        ),
                        actionButton(ns("input_path_browse_dir"), "Folder",
                          class = "btn btn-outline-secondary"
                        )
                      )
                    ),
                    textInput(ns("input_path"), NULL,
                      placeholder = "/path/to/file.fastq.gz  or  /path/to/directory",
                      width = "100%"
                    )
                  ),
                )
              ),
              conditionalPanel(
                condition = sprintf("input['%s']", ns("paired_end")),
                div(
                  class = "row",
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Forward Reads (R1)"),
                    div(
                      class = "file-browse-group",
                      div(
                        class = "drop-zone",
                        div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                        actionButton(ns("input_r1_browse"), "Browse",
                          class = "btn btn-outline-secondary"
                        )
                      ),
                      textInput(ns("input_r1"), NULL,
                        placeholder = "/path/to/sample_R1.fastq.gz",
                        width = "100%"
                      )
                    ),
                  ),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Reverse Reads (R2)"),
                    div(
                      class = "file-browse-group",
                      div(
                        class = "drop-zone",
                        div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                        actionButton(ns("input_r2_browse"), "Browse",
                          class = "btn btn-outline-secondary"
                        )
                      ),
                      textInput(ns("input_r2"), NULL,
                        placeholder = "/path/to/sample_R2.fastq.gz",
                        width = "100%"
                      )
                    ),
                  )
                )
              ),

              # ── Additional samples (batch mode) ────────────────────
              uiOutput(ns("sample1_name_row")),
              uiOutput(ns("extra_sample_rows")),
              div(
                class = "d-flex gap-2 mt-2",
                actionButton(ns("add_sample_row"), "+ Add sample",
                  class = "btn btn-sm btn-outline-primary"),
                actionButton(ns("remove_sample_row"), "Remove last",
                  class = "btn btn-sm btn-outline-secondary")
              ),
              tags$small(class = "text-muted",
                "Add more samples to analyse a cohort in one run. Each sample gets its own name, ",
                "input files, and results folder; a comparison report is generated automatically."
              )
            )
          ),

          div(
            class = "card mb-4",
            div(
              class = "card-body",
              h2(icon("gears"), " Processing Parameters"),
              div(
                class = "mb-4",
                tags$label(class = "form-label",
                  tags$span("Quality Score Threshold: "),
                  tags$span(class = "text-primary", textOutput(ns("quality_threshold_display"), inline = TRUE))
                ),
                sliderInput(ns("quality_threshold"), NULL, min = 0, max = 40, value = 20, step = 1),
                tags$small(class = "text-muted", "0 (worst) → 40 (high)")
              ),
              div(
                class = "mb-4",
                tags$label(class = "form-label",
                  tags$span("Minimum Read Length: "),
                  tags$span(class = "text-primary", textOutput(ns("min_read_length_display"), inline = TRUE), " bp")
                ),
                sliderInput(ns("min_read_length"), NULL, min = 20, max = 300, value = 50, step = 10),
                tags$small(class = "text-muted", "20 bp → 300 bp")
              ),
              div(
                class = "row",
                div(
                  class = "col-md-6 mb-3",
                  checkboxInput(ns("trim_adapter"), "Trim Adapter Sequences", value = TRUE)
                ),
                div(
                  class = "col-md-6 mb-3",
                  checkboxInput(ns("demultiplex"), "Demultiplex", value = FALSE)
                )
              ),

              div(
                class = "mb-3",
                tags$label(class = "form-label", "Primer Sequences"),
                textAreaInput(ns("primer_sequences"), NULL,
                  placeholder = "Enter primer sequences (one per line, forward then reverse)",
                  rows = 3,
                  value = ""
                ),
                tags$small(class = "text-muted", "Optional. Leave empty to skip primer trimming.")
              ),

              div(
                class = "mb-3",
                tags$label(class = "form-label", "Barcode Sequences"),
                textAreaInput(ns("barcode_sequences"), NULL,
                  placeholder = "Enter barcode sequences (one per line)",
                  rows = 3,
                  value = ""
                ),
                tags$small(class = "text-muted", "Optional. Used for demultiplexing.")
              ),

              div(
                class = "mb-3",
                tags$label(class = "form-label", "Barcoding Kit (Optional)"),
                textInput(ns("barcoding_kit"), NULL, placeholder = "e.g., EXP-NBD104")
              ),

              div(
                class = "mb-3",
                checkboxInput(ns("manually_allocate_threads"), "Manually allocate threads", value = FALSE)
              ),

              conditionalPanel(
                condition = sprintf("input['%s']", ns("manually_allocate_threads")),
                div(
                  class = "mb-3",
                  tags$label(class = "form-label", "Number of Threads"),
                  numericInput(ns("threads"), NULL, value = 4, min = 1, max = 32)
                )
              ),

              div(
                class = "mb-3",
                tags$label(class = "form-label", "External Database Directory (Optional)"),
                div(
                  class = "file-browse-group",
                  div(
                    class = "drop-zone",
                    div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                    actionButton(ns("external_db_dir_browse"), "Browse",
                      class = "btn btn-outline-secondary"
                    )
                  ),
                  textInput(ns("external_db_dir"), NULL,
                    placeholder = "/path/to/database",
                    width = "100%"
                  )
                ),
              ),

              conditionalPanel(
                condition = sprintf("input['%s'] == 'sr_meta' && input['%s'] != ''", ns("pipeline"), ns("external_db_dir")),
                div(
                  class = "mb-3",
                  tags$label(class = "form-label", "Database Type (if using external database)"),
                  selectInput(ns("database_type"), NULL,
                    choices = c("Auto-detect" = "auto", "Kraken2" = "kraken2"),
                    selected = "auto"
                  )
                )
              )
            )
          ),

          div(
            class = "card mb-4",
            div(
              class = "card-body",
              h2("Analysis Configuration"),
              div(
                class = "row",
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Sequencing Approach"),
                  selectInput(ns("pipeline"), NULL,
                    choices = c("16S rRNA Sequencing" = "sr_amp", "Metagenomics (WGS)" = "sr_meta"),
                    selected = "sr_amp"
                  )
                ),
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Sample Type"),
                  selectInput(ns("sample_type"), NULL,
                    choices = c("Vaginal" = "vaginal", "Gut" = "gut", "Oral" = "oral", "Skin" = "skin", "Other" = "other"),
                    selected = "vaginal"
                  )
                ),
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Run Scope"),
                  selectInput(ns("run_scope"), NULL,
                    choices = c("Full Pipeline" = "full", "QC Only" = "qc", "Analysis Only" = "analysis"),
                    selected = "full"
                  )
                ),
                conditionalPanel(
                  condition = sprintf("input['%s'] == 'vaginal'", ns("sample_type")),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "VALENCIA Classification"),
                    selectInput(ns("valencia"), NULL, choices = c("Yes" = "yes", "No" = "no"), selected = "yes")
                  )
                ),
                conditionalPanel(
                  condition = sprintf("input['%s'] == 'sr_amp'", ns("pipeline")),
                  div(
                    class = "col-md-12",
                    tags$h4("DADA2 Parameters"),
                    div(
                      class = "row",
                      div(
                        class = "col-md-6 mb-3",
                        tags$label(class = "form-label", "Forward Truncation Length"),
                        numericInput(ns("dada2_trunc_f"), NULL, value = 220, min = 50, max = 300),
                        tags$small(class = "text-muted", "Truncate forward reads at this position. Common: 220bp for 2x250bp, 140bp for 2x150bp")
                      ),
                      div(
                        class = "col-md-6 mb-3",
                        tags$label(class = "form-label", "Reverse Truncation Length"),
                        numericInput(ns("dada2_trunc_r"), NULL, value = 200, min = 50, max = 300),
                        tags$small(class = "text-muted", "Truncate reverse reads at this position")
                      )
                    ),
                    tags$div(
                      class = "alert alert-warning",
                      icon("triangle-exclamation"),
                      " Set these values shorter than your read length. Common: 220/200 for 2x250bp, 140/140 for 2x150bp"
                    )
                  )
                ),
                conditionalPanel(
                  condition = sprintf("input['%s'] == 'sr_meta'", ns("pipeline")),
                  div(
                    class = "col-md-12 mb-3",
                    tags$label(class = "form-label", "Kraken2 Database Path"),
                    div(
                      class = "file-browse-group",
                      div(
                        class = "drop-zone",
                        div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                        actionButton(ns("kraken_db_browse"), "Browse",
                          class = "btn btn-outline-secondary"
                        )
                      ),
                      textInput(ns("kraken_db"), NULL,
                        placeholder = "/path/to/kraken2/db",
                        width = "100%"
                      )
                    ),
                  ),
                  div(
                    class = "col-md-12 mb-3",
                    checkboxInput(ns("human_depletion"), "Human Read Depletion", value = FALSE)
                  ),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Kraken2 Confidence Threshold"),
                    numericInput(ns("kraken_confidence"), NULL, value = 0.05, min = 0, max = 1, step = 0.01),
                    tags$small(class = "text-muted", "Fraction of k-mers supporting classification (0–1). Site defaults: vaginal=0.02, gut=0.03, oral=0.04, skin=0.03")
                  ),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Kraken2 Minimum Hit Groups"),
                    numericInput(ns("kraken_min_hit_groups"), NULL, value = 2L, min = 1, max = 100, step = 1),
                    tags$small(class = "text-muted", "Distinct k-mer hit groups required for a classification. Site defaults: vaginal=2, gut=4, oral=4, skin=4")
                  ),
                  div(
                    class = "col-md-12 mb-3",
                    checkboxInput(ns("kraken_memory_mapping"), "Kraken2 Memory Mapping (low-RAM mode)", value = FALSE),
                    tags$small(class = "text-muted", "Use disk I/O instead of loading the full database into RAM. Slower but reduces memory usage.")
                  )
                ),
                div(
                  class = "col-md-12 mb-3",
                  tags$h4("Output Types"),
                  div(
                    class = "row",
                    div(
                      class = "col-md-6",
                      checkboxInput(ns("output_raw_csv"), "Raw Data (.csv)", value = TRUE)
                    ),
                    div(
                      class = "col-md-6",
                      checkboxInput(ns("output_pie_chart"), "Pie Chart", value = FALSE)
                    ),
                    div(
                      class = "col-md-6",
                      checkboxInput(ns("output_heatmap"), "Heatmap", value = FALSE)
                    ),
                    div(
                      class = "col-md-6",
                      checkboxInput(ns("output_stacked_bar"), "Stacked Bar Chart", value = FALSE)
                    ),
                    div(
                      class = "col-md-6",
                      checkboxInput(ns("output_quality_reports"), "Quality Reports", value = TRUE)
                    )
                  )
                )
              )
            )
          ),

          # ── Sample Barcode Mapping (Optional) ─────────────────────
          conditionalPanel(
            condition = sprintf("input['%s'] == true", ns("demultiplex")),
            div(
              class = "card mb-4",
              div(
                class = "card-body",
                h4("Sample Barcode Mapping (Optional)"),
                tags$p(
                  class = "text-muted",
                  style = "font-size: 0.875rem;",
                  "Map barcode numbers to meaningful sample names. Leave the name empty to keep the raw barcode ID."
                ),
                uiOutput(ns("barcode_map_rows")),
                div(
                  class = "d-flex gap-2 mt-2",
                  actionButton(ns("add_barcode_row"), "+ Add barcode",
                    class = "btn btn-sm btn-outline-primary"),
                  actionButton(ns("remove_barcode_row"), "Remove last",
                    class = "btn btn-sm btn-outline-secondary")
                )
              )
            )
          )
        ),

        div(
          class = "col-lg-4",
          div(
            class = "summary-panel",
            h2("Run Configuration"),
            div(
              class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Technology"),
              p(style = "margin: 0;", textOutput(ns("summary_technology")))
            ),
            div(
              class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Approach"),
              p(style = "margin: 0;", textOutput(ns("summary_pipeline")))
            ),
            div(
              class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Sample Type"),
              p(style = "margin: 0;", textOutput(ns("summary_sample_type")))
            ),
            div(
              class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Run Scope"),
              p(style = "margin: 0;", textOutput(ns("summary_run_scope")))
            ),
            conditionalPanel(
              condition = sprintf("input['%s'] == 'vaginal'", ns("sample_type")),
              div(
                class = "alert alert-info",
                icon("info-circle"), " VALENCIA classification will be performed"
              )
            ),
            uiOutput(ns("validation_messages")),
            hr(),
            actionButton(ns("run_pipeline"), "Run Pipeline",
              icon = icon("play"),
              class = "btn btn-primary w-100 mb-2"
            ),
            actionButton(ns("dry_run"), "Preview Configuration",
              icon = icon("eye"),
              class = "btn btn-outline-secondary w-100"
            )
          )
        )
      )
    )
  )
}
