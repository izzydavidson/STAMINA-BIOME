compare_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(
      class = "container-fluid p-4",

      div(
        class = "mb-4",
        h1("Compare Pipeline Outputs"),
        p(class = "text-muted", "Compare taxonomic profiles from two runs side by side — relative abundance, alpha diversity, beta diversity, and shared taxa.")
      ),

      # ── Input card ──────────────────────────────────────────────────────────
      div(
        class = "card mb-4",
        div(
          class = "card-body",
          h2("Input"),

          # Mode selector
          div(
            class = "mb-3",
            radioButtons(ns("input_mode"), NULL,
              choices  = c("Upload CSV files" = "csv", "Select completed runs" = "runs"),
              selected = "csv",
              inline   = TRUE
            )
          ),

          # ── CSV upload mode ────────────────────────────────────────────────
          conditionalPanel(
            condition = sprintf("input['%s'] == 'csv'", ns("input_mode")),
            div(
              class = "alert alert-info mb-3",
              style = "font-size: 0.875rem;",
              icon("info-circle"),
              " Upload any ",
              tags$code("*_species_tidy.csv"),
              " or ",
              tags$code("*_genus_tidy.csv"),
              " file from your pipeline outputs folder. Expected columns: ",
              tags$code("sample_id"), ", ", tags$code("species"), " (or ", tags$code("genus"), "), ",
              tags$code("abundance"), " (or ", tags$code("fraction"), ")."
            ),
            div(
              class = "row",
              div(
                class = "col-md-5 mb-3",
                tags$label(class = "form-label", "File A"),
                div(
                  class = "file-browse-group",
                  div(
                    class = "drop-zone",
                    div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                    actionButton(ns("path_a_browse"), "Browse",
                      class = "btn btn-outline-secondary"
                    )
                  ),
                  textInput(ns("path_a"), NULL,
                    placeholder = "/path/to/file_a.csv",
                    width = "100%"
                  )
                ),
                div(class = "mt-2",
                  textInput(ns("label_a"), "Label", placeholder = "e.g. Run A, Patient group")
                )
              ),
              div(
                class = "col-md-5 mb-3",
                tags$label(class = "form-label", "File B"),
                div(
                  class = "file-browse-group",
                  div(
                    class = "drop-zone",
                    div(class = "drop-zone-header", icon("upload"), " Drag & drop"),
                    actionButton(ns("path_b_browse"), "Browse",
                      class = "btn btn-outline-secondary"
                    )
                  ),
                  textInput(ns("path_b"), NULL,
                    placeholder = "/path/to/file_b.csv",
                    width = "100%"
                  )
                ),
                div(class = "mt-2",
                  textInput(ns("label_b"), "Label", placeholder = "e.g. Run B, Control group")
                )
              )
            )
          ),

          # ── Run selection mode ─────────────────────────────────────────────
          conditionalPanel(
            condition = sprintf("input['%s'] == 'runs'", ns("input_mode")),
            div(
              class = "row",
              div(
                class = "col-md-5 mb-3",
                tags$label(class = "form-label", "Run 1"),
                selectInput(ns("run1"), NULL, choices = NULL)
              ),
              div(
                class = "col-md-5 mb-3",
                tags$label(class = "form-label", "Run 2"),
                selectInput(ns("run2"), NULL, choices = NULL)
              )
            )
          ),

          # ── Shared options ─────────────────────────────────────────────────
          div(
            class = "row mt-1",
            div(
              class = "col-md-4 mb-3",
              tags$label(class = "form-label", "Taxonomic rank"),
              selectInput(ns("rank"), NULL,
                choices  = c("Species" = "species", "Genus" = "genus"),
                selected = "species"
              )
            )
          ),

          actionButton(ns("compare_btn"), "Compare",
            icon  = icon("code-compare"),
            class = "btn btn-primary"
          )
        )
      ),

      # ── Results ─────────────────────────────────────────────────────────────
      conditionalPanel(
        condition = sprintf("output['%s']", ns("has_results")),

        div(
          class = "card",
          div(
            class = "card-body",
            h2("Results"),
            uiOutput(ns("result_header")),
            hr(),
            tabsetPanel(
              id = ns("result_tabs"),

              # Tab 1: Relative abundance
              tabPanel(
                "Relative Abundance",
                div(
                  class = "mt-3",
                  plotOutput(ns("abundance_plot"), height = "480px"),
                  hr(),
                  h5("Top 30 taxa — mean relative abundance per run"),
                  tableOutput(ns("abundance_table"))
                )
              ),

              # Tab 2: Alpha diversity
              tabPanel(
                "Alpha Diversity",
                div(
                  class = "mt-3",
                  div(
                    class = "alert alert-info",
                    style = "font-size: 0.875rem;",
                    icon("info-circle"),
                    " Per-sample diversity metrics. Shannon entropy accounts for both richness and evenness. Pielou evenness = 1 means all taxa equally abundant."
                  ),
                  tableOutput(ns("alpha_table"))
                )
              ),

              # Tab 3: Beta diversity
              tabPanel(
                "Beta Diversity",
                div(
                  class = "mt-3",
                  div(
                    class = "alert alert-info",
                    style = "font-size: 0.875rem;",
                    icon("info-circle"),
                    " Bray-Curtis dissimilarity (0 = identical, 1 = no shared taxa). Rows and columns are labelled as ", tags$code("Run :: sample_id"), "."
                  ),
                  tableOutput(ns("beta_table"))
                )
              ),

              # Tab 4: Shared / unique taxa
              tabPanel(
                "Shared / Unique Taxa",
                div(
                  class = "mt-3",
                  verbatimTextOutput(ns("shared_summary")),
                  hr(),
                  tableOutput(ns("shared_table"))
                )
              )
            )
          )
        )
      )
    )
  )
}
