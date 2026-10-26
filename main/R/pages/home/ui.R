library(shiny)
library(bslib)

ui <- page_fluid(
  theme = bs_theme(
    version = 5,
    primary = "#2D89C8"
  ),
  
  tags$style(HTML("
    .home-wrap {
      max-width: 980px;
      margin: 0 auto;
      padding: 1.25rem 0.75rem 2rem 0.75rem;
    }
    .home-hero h1 {
      margin-bottom: 0.35rem;
    }
    .home-hero p {
      margin-bottom: 1.1rem;
      max-width: 70ch;
    }
    .home-card {
      height: 100%;
    }
  ")),
  
  div(
    class = "home-wrap",
    
    div(
      class = "home-hero",
      h1("STAMINA-BIOME"),
      p(
        "STAMINA-BIOME – Standardised, Technology-Agnostic Framework for Microbiome Investigation and Analysis. ",
        "A lightweight interface for preparing microbial sequencing runs and standardising outputs. ",
        "This is the home screen for now while the workflow UI is being built."
      )
    ),
    
    fluidRow(
      column(
        6,
        card(
          class = "home-card",
          card_header("Start a run"),
          card_body(
            p("Upload sequencing data, choose a preset, and generate a run config for your pipeline.")
          )
        )
      ),
      column(
        6,
        card(
          class = "home-card",
          card_header("Docs & presets"),
          card_body(
            p("View recommended presets for sample types, platforms, and output styles before running.")
          )
        )
      )
    )
  )
)

server <- function(input, output, session) {}

shinyApp(ui, server)
