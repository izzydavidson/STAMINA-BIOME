# ---------------------------------------------------------------------------
# setup_wizard_ui.R
# Full-screen setup wizard overlay — shown on first launch and via
# "Return to Wizard" dashboard button.  NOT a nav tab.
# ---------------------------------------------------------------------------

WIZARD_CSS <- "
/* ---- Overlay root ---- */
#setup-wizard-overlay {
  position: fixed;
  inset: 0;
  background: #f8fafc;
  z-index: 9999;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
}

/* ---- Top bar ---- */
.wiz-topbar {
  background: linear-gradient(135deg, #1e293b 0%, #334155 100%);
  color: white;
  padding: 0.875rem 2rem;
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-shrink: 0;
  box-shadow: 0 4px 6px -1px rgba(0,0,0,.15);
}
.wiz-brand { font-size: 1.35rem; font-weight: 700; letter-spacing: -0.02em; }
.wiz-brand-sub { font-size: 0.78rem; opacity: .65; margin-top: 1px; }

/* ---- Scrollable content ---- */
.wiz-body {
  flex: 1;
  max-width: 860px;
  margin: 0 auto;
  padding: 2rem 1.5rem 6rem;
  width: 100%;
}

/* ---- Section card ---- */
.wiz-section {
  background: white;
  border: 1px solid #e2e8f0;
  border-radius: 0.75rem;
  padding: 1.5rem;
  margin-bottom: 1.25rem;
  box-shadow: 0 1px 3px rgba(0,0,0,.06);
}
.wiz-section-hdr {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 0.625rem;
  padding-bottom: 0.75rem;
  border-bottom: 1px solid #f1f5f9;
}
.wiz-step-badge {
  background: #3b82f6;
  color: white;
  width: 30px; height: 30px;
  border-radius: 50%;
  display: flex; align-items: center; justify-content: center;
  font-size: 0.8125rem; font-weight: 700;
  flex-shrink: 0;
}
.wiz-section-title { font-size: 1.0625rem; font-weight: 700; color: #1e293b; }
.wiz-section-desc  { color: #64748b; font-size: 0.84rem; margin-bottom: 0.875rem; line-height: 1.5; }

/* ---- Item cards ---- */
.wiz-item {
  border: 2px solid #e2e8f0;
  border-radius: 0.5rem;
  padding: 0.875rem 1rem;
  margin-bottom: 0.5rem;
  display: flex;
  align-items: flex-start;
  gap: 0.75rem;
  cursor: pointer;
  transition: border-color .15s, background .15s;
  position: relative;
  background: white;
}
.wiz-item:hover                { border-color: #3b82f6; background: #f8fafc; }
.wiz-item.wiz-selected         { border-color: #3b82f6; background: #eff6ff; }
.wiz-item.wiz-selected:hover   { border-color: #2563eb; background: #dbeafe; }
.wiz-item.wiz-selected .wiz-item-name { color: #1d4ed8; }
.wiz-item.wiz-installed        { border-color: #10b981; background: #f0fdf4; cursor: default; }
.wiz-item.wiz-installed:hover  { border-color: #059669; background: #dcfce7; }

.wiz-installed-badge {
  position: absolute;
  top: 0.5rem; right: 0.75rem;
  background: #10b981;
  color: white;
  font-size: 0.68rem; font-weight: 700;
  padding: 0.2rem 0.55rem;
  border-radius: 9999px;
  text-transform: uppercase;
  letter-spacing: .05em;
}

.wiz-item-body  { flex: 1; min-width: 0; }
.wiz-item-name  { font-weight: 600; color: #1e293b; font-size: 0.9rem; margin-bottom: 2px; }
.wiz-item-desc  { color: #64748b; font-size: 0.8125rem; margin-bottom: 2px; }
.wiz-item-meta  { color: #94a3b8; font-size: 0.75rem; }

/* ---- Docker row ---- */
.wiz-docker-row {
  display: flex; align-items: center; gap: 0.75rem;
  padding: 0.875rem; background: #f8fafc;
  border: 1px solid #e2e8f0; border-radius: 0.5rem;
  margin-top: 0.625rem;
}
.wiz-docker-icon {
  width: 28px; height: 28px; border-radius: 50%;
  display: flex; align-items: center; justify-content: center;
  font-size: 14px; flex-shrink: 0;
}
.wiz-dok-ok  { background: #dcfce7; color: #059669; }
.wiz-dok-err { background: #fee2e2; color: #dc2626; }
.wiz-dok-chk { background: #fef3c7; color: #b45309; font-size: 11px; }

/* ---- Progress ---- */
.wiz-progress-card {
  background: white;
  border: 1px solid #e2e8f0;
  border-radius: 0.75rem;
  padding: 1.5rem;
  margin-bottom: 1.25rem;
  box-shadow: 0 1px 3px rgba(0,0,0,.06);
}
.wiz-prog-label { color: #475569; font-size: 0.84rem; margin-bottom: 0.375rem; }
.wiz-prog-track {
  background: #e2e8f0; height: 10px;
  border-radius: 5px; overflow: hidden; margin-bottom: 1rem;
}
.wiz-prog-fill {
  background: linear-gradient(90deg, #3b82f6 0%, #2563eb 100%);
  height: 100%; width: 0%; transition: width .4s ease;
}
.wiz-log-box {
  background: #0f172a; border-radius: 0.5rem;
  padding: 1rem;
  font-family: 'SF Mono', 'Fira Code', 'Courier New', monospace;
  font-size: 0.8rem; color: #cbd5e1;
  max-height: 320px; overflow-y: auto;
  line-height: 1.6;
}
.wiz-ll { margin-bottom: 1px; white-space: pre-wrap; word-break: break-word; }
.wiz-ll-ok  { color: #4ade80; font-weight: 500; }
.wiz-ll-err { color: #f87171; font-weight: 500; }
.wiz-ll-hdr { color: #93c5fd; font-weight: 600; }

/* ---- Sticky footer ---- */
.wiz-footer {
  position: fixed;
  bottom: 0; left: 0; right: 0;
  background: white;
  border-top: 1px solid #e2e8f0;
  padding: 0.875rem 1.75rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
  box-shadow: 0 -4px 6px -1px rgba(0,0,0,.06);
  z-index: 10;
}
.wiz-footer-right { display: flex; gap: 0.625rem; align-items: center; }
.wiz-sel-count { color: #475569; font-size: 0.84rem; }
"

WIZARD_JS <- "
// Card click — toggle .wiz-selected class and update footer count badge.
// IDs are read from data-wiz-id attributes; no Shiny checkbox inputs needed.
$(document).on('click', '.wiz-item:not(.wiz-installed)', function(e) {
  $(this).toggleClass('wiz-selected');
  var count = $('.wiz-item.wiz-selected').length;
  Shiny.setInputValue('setup_wizard-wiz_n_sel', count, {priority: 'event'});
});
"

# ---------------------------------------------------------------------------
# UI function (always in DOM — shown/hidden by app.R server via shinyjs)
# ---------------------------------------------------------------------------
setup_wizard_ui <- function(id) {
  ns <- NS(id)

  tagList(
    tags$style(HTML(WIZARD_CSS)),
    tags$script(HTML(WIZARD_JS)),

    # ---- Top bar -------------------------------------------------------
    div(class = "wiz-topbar",
        div(
          div(class = "wiz-brand", "\U0001F9EC STAMINA-BIOME"),
          div(class = "wiz-brand-sub",
              "Setup Wizard — configure your analysis environment")
        ),
        tags$span(style = "opacity:.5; font-size:.75rem;",
                  "Complete setup to unlock all pipelines")
    ),

    # ---- Scrollable body -----------------------------------------------
    div(class = "wiz-body",

        # Step 1 — Docker
        div(class = "wiz-section",
            div(class = "wiz-section-hdr",
                div(class = "wiz-step-badge", "1"),
                span(class = "wiz-section-title", "Docker")),
            p(class = "wiz-section-desc",
              "STAMINA-BIOME runs all pipelines inside Docker containers. Docker must be installed and running before you can analyse samples."),
            uiOutput(ns("docker_status_ui"))
        ),

        # Step 2 — Databases
        div(class = "wiz-section",
            div(class = "wiz-section-hdr",
                div(class = "wiz-step-badge", "2"),
                span(class = "wiz-section-title", "Reference Databases")),
            p(class = "wiz-section-desc",
              "Select the databases required for your pipeline type. Green cards are already installed."),
            uiOutput(ns("databases_ui"))
        ),

        # Step 3 — Tools (VALENCIA + Dorado binaries + Bracken readlen)
        div(class = "wiz-section",
            div(class = "wiz-section-hdr",
                div(class = "wiz-step-badge", "3"),
                span(class = "wiz-section-title", "Analysis Tools")),
            p(class = "wiz-section-desc",
              "Optional tools for specific sample types (e.g. vaginal CST classification). Also select a Dorado binary here \u2014 required before downloading basecalling models in Step 4."),
            uiOutput(ns("tools_ui")),
            hr(style = "margin: 1rem 0 0.75rem;"),
            div(style = "display:flex; align-items:center; gap:1rem;",
                div(style = "flex:1;",
                    tags$label(style = "font-weight:600; color:#1e293b; font-size:0.9rem;",
                               "Bracken Read Length"),
                    p(style = "color:#64748b; font-size:0.8125rem; margin:2px 0 0;",
                      "kmer_distrib read length for Bracken abundance re-estimation. ",
                      tags$b("Auto-detect"), " scans the selected database directory for available lengths and picks the largest.")),
                div(style = "width:180px; flex-shrink:0;",
                    selectInput(ns("bracken_readlen"), NULL,
                                choices = c("Auto-detect" = "auto",
                                            "500 bp"  = "500",
                                            "750 bp"  = "750",
                                            "1000 bp" = "1000",
                                            "1200 bp" = "1200",
                                            "1500 bp" = "1500",
                                            "2000 bp" = "2000"),
                                selected = "auto",
                                width = "100%"))
            )
        ),

        # Step 4 — Dorado models
        div(class = "wiz-section",
            div(class = "wiz-section-hdr",
                div(class = "wiz-step-badge", "4"),
                span(class = "wiz-section-title", "Dorado Basecalling Models")),
            p(class = "wiz-section-desc",
              "Required for long-read pipelines starting from FAST5/POD5 raw signal files. Install a Dorado binary in Step 3 first, then select models below."),
            uiOutput(ns("models_ui"))
        ),

        # Progress card (hidden until install begins)
        div(id = ns("wiz-prog-wrap"), style = "display:none;",
            div(class = "wiz-progress-card",
                h3(style = "font-size:.9375rem; font-weight:700; color:#1e293b; margin-bottom:.875rem;",
                   "Installation Progress"),
                div(class = "wiz-prog-label", textOutput(ns("prog_label"))),
                div(class = "wiz-prog-track",
                    div(id  = ns("wiz-prog-fill"), class = "wiz-prog-fill")),
                div(class = "wiz-log-box", id = ns("wiz-log-box"),
                    uiOutput(ns("install_log_ui")))
            )
        )
    ),

    # ---- Sticky footer -------------------------------------------------
    div(class = "wiz-footer",
        actionButton(ns("skip_wizard"), "Skip for Now",
                     class = "btn btn-outline-secondary btn-sm"),
        div(class = "wiz-footer-right",
            uiOutput(ns("sel_count_ui")),
            actionButton(ns("start_install"), "Download & Install Selected",
                         icon  = icon("download"),
                         class = "btn btn-primary btn-sm")
        )
    )
  )
}
