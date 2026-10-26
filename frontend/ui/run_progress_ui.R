run_progress_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(
      class = "container-fluid p-4",

      # Page header
      div(
        class = "mb-4",
        h1("Pipeline Execution"),
        p(class = "text-muted", "Real-time pipeline progress and logs")
      ),

      # Run information card
      div(
        class = "card mb-4",
        div(
          class = "card-body",
          h2("Run Information"),
          div(
            class = "row",
            div(
              class = "col-md-3",
              tags$label(class = "text-muted", "Run ID"),
              p(textOutput(ns("run_id")))
            ),
            div(
              class = "col-md-3",
              tags$label(class = "text-muted", "Pipeline"),
              p(textOutput(ns("pipeline_name")))
            ),
            div(
              class = "col-md-3",
              tags$label(class = "text-muted", "Status"),
              uiOutput(ns("run_status_badge"))
            ),
            div(
              class = "col-md-3",
              tags$label(class = "text-muted", "Started"),
              p(textOutput(ns("start_time")))
            )
          ),
          hr(),
          div(
            class = "mb-3",
            tags$label(class = "text-muted", "Command"),
            tags$pre(
              style = "background: #f3f4f6; padding: 1rem; border-radius: 0.375rem; font-size: 0.875rem; overflow-x: auto;",
              textOutput(ns("command_display"))
            )
          )
        )
      ),

      # Terminal output
      div(
        class = "card",
        div(
          class = "card-body",
          div(
            class = "d-flex justify-content-between align-items-center mb-3",
            h2("Pipeline Logs"),
            div(
              class = "d-flex align-items-center gap-2",
              checkboxInput(ns("auto_scroll"), "Auto-scroll", value = TRUE),
              actionButton(ns("clear_logs"), "Clear", class = "btn btn-sm btn-outline-secondary"),
              actionButton(ns("refresh_logs"), "Refresh", icon = icon("rotate"), class = "btn btn-sm btn-outline-primary")
            )
          ),
          div(
            class = "terminal-output",
            id = ns("log_output"),
            uiOutput(ns("log_content"))
          )
        )
      ),

      # Control buttons
      div(
        class = "mt-4 d-flex gap-2",
        actionButton(ns("stop_run"), "Stop Pipeline", icon = icon("stop"), class = "btn btn-danger"),
        actionButton(ns("view_outputs"), "View Outputs", icon = icon("folder-open"), class = "btn btn-outline-primary"),
        actionButton(ns("return_dashboard"), "Return to Dashboard", icon = icon("home"), class = "btn btn-outline-secondary")
      )
    ),

    # Auto-scroll JavaScript
    tags$script(HTML(sprintf("
      setInterval(function() {
        var autoScroll = $('#%s').is(':checked');
        if (autoScroll) {
          var logDiv = document.getElementById('%s');
          if (logDiv) {
            logDiv.scrollTop = logDiv.scrollHeight;
          }
        }
      }, 500);
    ", ns("auto_scroll"), ns("log_output"))))
  )
}
