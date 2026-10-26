long_read_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(
      class = "container-fluid p-4",

      div(
        class = "mb-4",
        h1("Long Read Sequencing"),
        p(class = "text-muted", "Oxford Nanopore, PacBio platforms")
      ),

      div(
        class = "row",

        # Left column
        div(
          class = "col-lg-8",

          # ── Input Configuration ──────────────────────────────────
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
                  selectInput(ns("lr_technology"), NULL,
                    choices = c("Oxford Nanopore" = "ont", "PacBio" = "pacbio"),
                    selected = "ont"
                  )
                ),
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Input Type"),
                  selectInput(ns("input_format"), NULL,
                    choices = c("FASTQ" = "fastq", "FAST5" = "fast5", "POD5" = "pod5"),
                    selected = "fastq"
                  ),
                  uiOutput(ns("input_format_hint"))
                ),
                # Barcoding Kit — required when FAST5, optional when FASTQ
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label",
                    "Barcoding Kit",
                    conditionalPanel(
                      condition = sprintf("input['%s'] == 'fast5' || input['%s'] == 'pod5'", ns("input_format"), ns("input_format")),
                      tags$span(class = "text-danger", " *")
                    )
                  ),
                  textInput(ns("barcoding_kit"), NULL, placeholder = "e.g., SQK-RBK004")
                ),
                # Ligation Kit — required when FAST5, optional when FASTQ
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label",
                    "Ligation Kit",
                    conditionalPanel(
                      condition = sprintf("input['%s'] == 'fast5' || input['%s'] == 'pod5'", ns("input_format"), ns("input_format")),
                      tags$span(class = "text-danger", " *")
                    )
                  ),
                  textInput(ns("ligation_kit"), NULL, placeholder = "e.g., SQK-LSK109")
                ),
                div(
                  class = "col-md-6 mb-3",
                  tags$label(class = "form-label", "Run Name/ID"),
                  textInput(ns("run_name"), NULL, placeholder = "e.g., LR_2026_001")
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
                tags$label(class = "form-label", "Input File or Directory"),
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
              ),

              # Dorado config (FAST5/POD5 only)
              conditionalPanel(
                condition = sprintf("input['%s'] == 'fast5' || input['%s'] == 'pod5'", ns("input_format"), ns("input_format")),
                hr(),
                h3("Basecalling Configuration (Dorado)"),
                div(
                  class = "alert alert-info", role = "alert", style = "font-size: 0.875rem;",
                  icon("info-circle"), " Paths are auto-detected if Dorado was installed via Setup Wizard."
                ),
                div(
                  class = "row",
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Dorado Binary Path (optional)"),
                    div(
                      class = "file-browse-group",
                      div(
                        class = "drop-zone",
                        div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                        actionButton(ns("dorado_bin_browse"), "Browse",
                          class = "btn btn-outline-secondary"
                        )
                      ),
                      textInput(ns("dorado_bin"), NULL,
                        placeholder = "Auto-detected if installed via Setup Wizard",
                        width = "100%"
                      )
                    ),
                  ),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Dorado Models Directory (optional)"),
                    div(
                      class = "file-browse-group",
                      div(
                        class = "drop-zone",
                        div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                        actionButton(ns("dorado_models_dir_browse"), "Browse",
                          class = "btn btn-outline-secondary"
                        )
                      ),
                      textInput(ns("dorado_models_dir"), NULL,
                        placeholder = "Auto-detected if installed via Setup Wizard",
                        width = "100%"
                      )
                    ),
                  ),
                  div(
                    class = "col-md-12 mb-3",
                    tags$label(class = "form-label", "Dorado Model"),
                    selectInput(ns("dorado_model"), NULL,
                      choices = c("Loading..." = ""),
                      selected = ""
                    )
                  )
                )
              )
            )
          ),

          # ── Processing Parameters ────────────────────────────────
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
                sliderInput(ns("quality_threshold"), NULL, min = 0, max = 20, value = 7, step = 1),
                tags$small(class = "text-muted", "0 (Low) → 20 (High)")
              ),
              div(
                class = "mb-4",
                tags$label(class = "form-label",
                  tags$span("Minimum Read Length: "),
                  tags$span(class = "text-primary", textOutput(ns("min_read_length_display"), inline = TRUE), " bp")
                ),
                sliderInput(ns("min_read_length"), NULL, min = 0, max = 9000, value = 1000, step = 500),
                tags$small(class = "text-muted", "0 (no filter) \u2192 9000 bp")
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
                  placeholder = "Enter primer sequences (one per line)",
                  rows = 2, value = ""),
                tags$small(class = "text-muted", "Optional. Leave empty to skip primer trimming.")
              ),
              div(
                class = "mb-3",
                tags$label(class = "form-label", "Barcode Sequences"),
                textAreaInput(ns("barcode_sequences"), NULL,
                  placeholder = "Enter barcode sequences (one per line)",
                  rows = 2, value = ""),
                tags$small(class = "text-muted", "Optional. Used for demultiplexing.")
              ),
              div(
                class = "mb-3",
                tags$label(class = "form-label", "Number of Threads"),
                numericInput(ns("threads"), NULL, value = 4, min = 1, max = 32)
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
                condition = sprintf("input['%s'] == 'lr_meta' && input['%s'] != ''", ns("pipeline"), ns("external_db_dir")),
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

          # ── Analysis Configuration ───────────────────────────────
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
                    choices = c("16S rRNA Sequencing (Emu)" = "lr_amp", "Metagenomics" = "lr_meta"),
                    selected = "lr_amp"
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
                    choices = c("Full Pipeline" = "full", "QC Only" = "qc"),
                    selected = "full"
                  )
                ),
                conditionalPanel(
                  condition = sprintf("input['%s'] == 'vaginal'", ns("sample_type")),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "VALENCIA Classification"),
                    selectInput(ns("valencia"), NULL,
                      choices = c("Yes" = "yes", "No" = "no"), selected = "yes")
                  )
                ),
                # lr_meta: Kraken2 DB + Human depletion
                conditionalPanel(
                  condition = sprintf("input['%s'] == 'lr_meta'", ns("pipeline")),
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
                    checkboxInput(ns("human_depletion"), "Human Read Depletion", value = FALSE),
                    tags$small(class = "text-muted", "Remove human-derived sequences from the dataset")
                  ),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Kraken2 Confidence Threshold"),
                    numericInput(ns("kraken_confidence"), NULL, value = 0.05, min = 0, max = 1, step = 0.01),
                    tags$small(class = "text-muted", "Fraction of k-mers supporting classification (0\u20131). Site defaults: vaginal=0.02, gut=0.03, oral=0.04, skin=0.03")
                  ),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Kraken2 Minimum Hit Groups"),
                    numericInput(ns("kraken_min_hit_groups"), NULL, value = 2L, min = 1, max = 100, step = 1),
                    tags$small(class = "text-muted", "Distinct k-mer hit groups required for a classification. Site defaults: vaginal=2, gut=4, oral=4, skin=4")
                  )
                ),
                # lr_amp: Emu classifier params
                conditionalPanel(
                  condition = sprintf("input['%s'] == 'lr_amp'", ns("pipeline")),
                  div(
                    class = "col-md-6 mb-3",
                    tags$label(class = "form-label", "Emu Minimum Percent Identity"),
                    numericInput(ns("emu_min_pid"), NULL, value = 95, min = 0, max = 100, step = 1),
                    tags$small(class = "text-muted", "Recommended: 95")
                  )
                ),
                # Output Types
                div(
                  class = "col-md-12 mb-3",
                  tags$h4("Output Types"),
                  div(
                    class = "row",
                    div(class = "col-md-6",
                      checkboxInput(ns("output_raw_csv"), "Raw Data (.csv)", value = TRUE)),
                    div(class = "col-md-6",
                      checkboxInput(ns("output_pie_chart"), "Pie Chart", value = FALSE)),
                    div(class = "col-md-6",
                      checkboxInput(ns("output_heatmap"), "Heatmap", value = FALSE)),
                    div(class = "col-md-6",
                      checkboxInput(ns("output_stacked_bar"), "Stacked Bar Chart", value = FALSE)),
                    div(class = "col-md-6",
                      checkboxInput(ns("output_quality_reports"), "Quality Reports", value = FALSE))
                  )
                )
              )
            )
          ),

          # ── Samples (barcode mapping for demultiplexed runs) ─────
          conditionalPanel(
            condition = sprintf("input['%s'] != '' || input['%s'] == true", ns("barcoding_kit"), ns("demultiplex")),
            div(
              class = "card mb-4",
              div(
                class = "card-body",
                h4("Samples"),
                tags$p(
                  class = "text-muted",
                  style = "font-size: 0.875rem;",
                  "Name each sample in this multiplexed run. Barcode is optional — leave it blank ",
                  "to auto-assign in order (barcode01, barcode02, ...), or enter a specific barcode ",
                  "ID (e.g. BC01) to pin a sample to it. The selected barcoding kit determines the ",
                  "maximum number of samples available."
                ),
                uiOutput(ns("barcode_map_rows")),
                div(
                  class = "d-flex gap-2 mt-2",
                  actionButton(ns("add_barcode_row"), "+ Add sample",
                    class = "btn btn-sm btn-outline-primary"),
                  actionButton(ns("remove_barcode_row"), "Remove last",
                    class = "btn btn-sm btn-outline-secondary")
                )
              )
            )
          )
        ),

        # Right column — summary
        div(
          class = "col-lg-4",
          div(
            class = "summary-panel",
            h2("Run Configuration"),
            div(class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Technology"),
              p(style = "margin: 0;", textOutput(ns("summary_technology")))
            ),
            div(class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Approach"),
              p(style = "margin: 0;", textOutput(ns("summary_pipeline")))
            ),
            div(class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Input Format"),
              p(style = "margin: 0;", textOutput(ns("summary_format")))
            ),
            div(class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Sample Type"),
              p(style = "margin: 0;", textOutput(ns("summary_sample_type")))
            ),
            div(class = "summary-item",
              p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Run Scope"),
              p(style = "margin: 0;", textOutput(ns("summary_run_scope")))
            ),
            conditionalPanel(
              condition = sprintf("input['%s'] == 'vaginal'", ns("sample_type")),
              div(class = "alert alert-info",
                icon("info-circle"), " VALENCIA classification will be performed")
            ),
            uiOutput(ns("validation_messages")),
            hr(),
            actionButton(ns("run_pipeline"), "Run Pipeline",
              icon = icon("play"), class = "btn btn-primary w-100 mb-2"),
            actionButton(ns("dry_run"), "Preview Configuration",
              icon = icon("eye"), class = "btn btn-outline-secondary w-100")
          )
        )
      )
    )
  )
}
