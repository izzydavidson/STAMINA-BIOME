dashboard_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(
      class = "container-fluid p-4",

      # Page header
      div(
        class = "mb-4",
        h1("Dashboard"),
        p(class = "text-muted", "Overview of sequencing analysis projects")
      ),

      # Return to Wizard and Refresh buttons
      div(
        class = "mb-4 d-flex gap-2",
        actionButton(
          ns("return_to_wizard"),
          "Return to Wizard",
          icon = icon("wand-magic-sparkles"),
          class = "btn btn-primary"
        ),
        actionButton(
          ns("refresh_dashboard"),
          "Refresh",
          icon = icon("rotate"),
          class = "btn btn-outline-secondary"
        )
      ),

      # Stats Grid
      div(
        class = "row mb-4",
        div(
          class = "col-md-3",
          div(
            class = "stat-card",
            div(
              class = "d-flex justify-content-between align-items-center",
              div(
                p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Total Projects"),
                p(style = "font-size: 1.875rem; font-weight: 600; margin: 0;", textOutput(ns("total_projects"), inline = TRUE))
              ),
              div(
                class = "rounded p-3",
                style = "background-color: #dbeafe; color: #2563eb;",
                icon("file-text", class = "fa-2x")
              )
            )
          )
        ),
        div(
          class = "col-md-3",
          div(
            class = "stat-card",
            div(
              class = "d-flex justify-content-between align-items-center",
              div(
                p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Completed"),
                p(style = "font-size: 1.875rem; font-weight: 600; margin: 0;", textOutput(ns("completed_projects"), inline = TRUE))
              ),
              div(
                class = "rounded p-3",
                style = "background-color: #dcfce7; color: #16a34a;",
                icon("check-circle", class = "fa-2x")
              )
            )
          )
        ),
        div(
          class = "col-md-3",
          div(
            class = "stat-card",
            div(
              class = "d-flex justify-content-between align-items-center",
              div(
                p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "In Progress"),
                p(style = "font-size: 1.875rem; font-weight: 600; margin: 0;", textOutput(ns("in_progress_projects"), inline = TRUE))
              ),
              div(
                class = "rounded p-3",
                style = "background-color: #fef3c7; color: #d97706;",
                icon("clock", class = "fa-2x")
              )
            )
          )
        ),
        div(
          class = "col-md-3",
          div(
            class = "stat-card",
            div(
              class = "d-flex justify-content-between align-items-center",
              div(
                p(class = "text-muted mb-1", style = "font-size: 0.875rem;", "Failed"),
                p(style = "font-size: 1.875rem; font-weight: 600; margin: 0;", textOutput(ns("failed_projects"), inline = TRUE))
              ),
              div(
                class = "rounded p-3",
                style = "background-color: #fee2e2; color: #dc2626;",
                icon("triangle-exclamation", class = "fa-2x")
              )
            )
          )
        )
      ),

      # Recent Projects Table
      div(
        class = "card",
        div(
          class = "card-body",
          h3("Recent Projects"),
          div(
            class = "table-responsive mt-3",
            tableOutput(ns("recent_projects_table"))
          )
        )
      )
    )
  )
}
