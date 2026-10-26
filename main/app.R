library(shiny)
library(bslib)

options(shiny.maxRequestSize = 5 * 1024^3) # 5GB upload limit

source("ui.R", local = TRUE)
source("server.R", local = TRUE)

shinyApp(ui = ui, server = server)
