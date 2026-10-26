#!/bin/bash
# ---------------------------------------------------------------------------
# Frontend pipeline wrapper.
# Calls the main stamina_biome_run.sh and, on success:
#   Layer 1 (bash): Directly copies results/tables, results/valencia,
#                   results/plots, and results/qc into final/ using plain
#                   cp — no R subprocess, guaranteed to succeed regardless
#                   of Shiny session state or library locks.
#   Layer 2 (R):   Runs frontend_postprocess.R for piechart re-run and
#                   manifest rewrite (bounded by processx timeout in G2).
#
# Does NOT modify main/ or cli/.
# Always exits with the PIPELINE exit code, never the postprocess exit code.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

MAIN_PIPELINE="$REPO_ROOT/main/pipelines/stamina_biome_run.sh"
FRONTEND_POSTPROCESS="$SCRIPT_DIR/pipelines/postprocess/r/frontend_postprocess.R"

if [ ! -f "$MAIN_PIPELINE" ]; then
  echo "[WRAPPER] ERROR: main pipeline script not found: $MAIN_PIPELINE" >&2
  exit 1
fi

# Run the main pipeline, passing all arguments through unchanged.
# Do NOT use set -e — capture exit code manually so postprocess failure
# cannot mask a pipeline success.
"$MAIN_PIPELINE" "$@"
PIPELINE_EXIT=$?

if [ "$PIPELINE_EXIT" -eq 0 ]; then

  # -------------------------------------------------------------------------
  # Layer 1: Direct bash copy of results/ -> final/
  # Parses config JSON with python3 (always available on macOS) to find the
  # exact paths. Uses plain cp — no R, no library locks, no graphics device.
  # -------------------------------------------------------------------------
  CONFIG_FILE=""
  _PREV=""
  for _ARG in "$@"; do
    if [ "$_PREV" = "--config" ]; then
      CONFIG_FILE="$_ARG"
    fi
    _PREV="$_ARG"
  done

  if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    WORK_DIR=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['run']['work_dir'])" "$CONFIG_FILE" 2>/dev/null)
    RUN_ID_RAW=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['run']['run_id'])" "$CONFIG_FILE" 2>/dev/null)
    PIPELINE_KEY=$(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['pipeline_id'])" "$CONFIG_FILE" 2>/dev/null)

    # Sanitize run_id the same way pipeline_modal_server.R does:
    #   tolower, keep only [a-z0-9_-], strip leading/trailing hyphens
    RUN_ID=$(printf '%s' "$RUN_ID_RAW" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-' | sed 's/^-*//' | sed 's/-*$//')

    if [ -n "$WORK_DIR" ] && [ -n "$RUN_ID" ] && [ -n "$PIPELINE_KEY" ]; then
      RESULTS_DIR="$WORK_DIR/$RUN_ID/results"
      FINAL_DIR="$WORK_DIR/$RUN_ID/final_results"

      echo "[WRAPPER] Layer 1: direct bash copy results/ -> final/"

      # tables: copy everything
      T_SRC="$RESULTS_DIR/tables"; T_DST="$FINAL_DIR/tables"
      if [ -d "$T_SRC" ] && [ -n "$(ls -A "$T_SRC" 2>/dev/null)" ]; then
        mkdir -p "$T_DST"
        cp "$T_SRC"/* "$T_DST/" 2>/dev/null || true
        echo "[WRAPPER]   tables: $(ls "$T_DST" 2>/dev/null | wc -l | tr -d ' ') file(s) -> $T_DST"
      else
        echo "[WRAPPER]   tables: source empty or missing, skipping"
      fi

      # valencia: copy everything
      V_SRC="$RESULTS_DIR/valencia"; V_DST="$FINAL_DIR/valencia"
      if [ -d "$V_SRC" ] && [ -n "$(ls -A "$V_SRC" 2>/dev/null)" ]; then
        mkdir -p "$V_DST"
        cp "$V_SRC"/* "$V_DST/" 2>/dev/null || true
        echo "[WRAPPER]   valencia: $(ls "$V_DST" 2>/dev/null | wc -l | tr -d ' ') file(s) -> $V_DST"
      else
        echo "[WRAPPER]   valencia: source empty or missing, skipping"
      fi

      # plots: images only (.png, .pdf) — CSV data files go to tables/ instead
      P_SRC="$RESULTS_DIR/plots"; P_DST="$FINAL_DIR/plots"
      if [ -d "$P_SRC" ] && [ -n "$(ls -A "$P_SRC" 2>/dev/null)" ]; then
        mkdir -p "$P_DST"
        mkdir -p "$T_DST"
        # Copy image files to final/plots/
        for IMG in "$P_SRC"/*.png "$P_SRC"/*.pdf "$P_SRC"/*.svg; do
          [ -f "$IMG" ] && cp "$IMG" "$P_DST/" 2>/dev/null || true
        done
        # Move CSV/TSV data files from plots/ to final/tables/
        for DAT in "$P_SRC"/*.csv "$P_SRC"/*.tsv; do
          [ -f "$DAT" ] && cp "$DAT" "$T_DST/" 2>/dev/null || true
        done
        echo "[WRAPPER]   plots: $(ls "$P_DST" 2>/dev/null | wc -l | tr -d ' ') image(s) -> $P_DST"
        echo "[WRAPPER]   plots->tables: plot data CSVs copied to $T_DST"
      else
        echo "[WRAPPER]   plots: source empty or missing, skipping"
      fi

      # qc: multiqc from results/qc/ (preserve subdirectories)
      QC_SRC="$RESULTS_DIR/qc"; QC_DST="$FINAL_DIR/qc"
      if [ -d "$QC_SRC" ]; then
        mkdir -p "$QC_DST"
        cp -R "$QC_SRC"/* "$QC_DST/" 2>/dev/null || true
        echo "[WRAPPER]   qc(multiqc): $(find "$QC_DST" -type f 2>/dev/null | wc -l | tr -d ' ') file(s) -> $QC_DST"
      fi

      # qc: FastQC HTML from <pipeline>/results/fastqc/ (main pipeline never promotes these to final/)
      FQC_SRC="$WORK_DIR/$RUN_ID/$PIPELINE_KEY/results/fastqc"
      FQC_DST="$FINAL_DIR/qc/fastqc"
      if [ -d "$FQC_SRC" ] && [ -n "$(ls -A "$FQC_SRC" 2>/dev/null)" ]; then
        mkdir -p "$FQC_DST"
        cp "$FQC_SRC"/*.html "$FQC_DST/" 2>/dev/null || true
        echo "[WRAPPER]   qc(fastqc): $(ls "$FQC_DST" 2>/dev/null | wc -l | tr -d ' ') HTML(s) -> $FQC_DST"
      fi
    else
      echo "[WRAPPER] WARNING: Could not parse config paths for direct copy" >&2
    fi
  else
    echo "[WRAPPER] WARNING: No --config argument found; skipping direct copy" >&2
  fi

  # -------------------------------------------------------------------------
  # Layer 2: R postprocess for piechart re-run, valencia collate, and
  # manifest rewrite.
  #
  # CRITICAL: Rscript output MUST be redirected to a log FILE, not the
  # processx pipe (stdout). The pipe is opened with stdout="|" in Shiny but
  # is NEVER READ by the observe loop — it only reads log files. After a
  # long pipeline run (e.g. 47 min of QIIME2 + Docker output), the pipe
  # buffer is full. Any cat() call in Rscript immediately blocks, causing
  # the entire postprocess to freeze silently before creating any files.
  #
  # The log file z_frontend_postprocess.log is automatically discovered by
  # discover_run_logs() (it scans *.log in <pipeline>/logs/) and shown in
  # the UI under "Z Frontend Postprocess".
  # -------------------------------------------------------------------------
  echo "[WRAPPER] Pipeline succeeded — running frontend postprocess"
  if [ -f "$FRONTEND_POSTPROCESS" ]; then
    # Build log path using already-parsed config values
    if [ -n "$WORK_DIR" ] && [ -n "$RUN_ID" ] && [ -n "$PIPELINE_KEY" ]; then
      PP_LOG_DIR="$WORK_DIR/$RUN_ID/$PIPELINE_KEY/logs"
      mkdir -p "$PP_LOG_DIR"
      PP_LOG="$PP_LOG_DIR/z_frontend_postprocess.log"
      echo "[WRAPPER] Frontend postprocess log -> $PP_LOG"
      Rscript "$FRONTEND_POSTPROCESS" "$@" > "$PP_LOG" 2>&1
    else
      # Fallback: write to a temp log to avoid pipe-buffer deadlock
      PP_LOG="/tmp/stamina_biome_frontend_postprocess_$$.log"
      echo "[WRAPPER] WARNING: Could not determine log path; writing to $PP_LOG"
      Rscript "$FRONTEND_POSTPROCESS" "$@" > "$PP_LOG" 2>&1
    fi
    PP_EXIT=$?
    if [ "$PP_EXIT" -ne 0 ]; then
      echo "[WRAPPER] WARNING: frontend postprocess exited with code $PP_EXIT (pipeline was OK)" >&2
    else
      echo "[WRAPPER] Frontend postprocess complete"
    fi
  else
    echo "[WRAPPER] WARNING: frontend postprocess script not found: $FRONTEND_POSTPROCESS" >&2
  fi

else
  echo "[WRAPPER] Pipeline exited with code $PIPELINE_EXIT — skipping frontend postprocess"
fi

# Always exit with the pipeline exit code
exit $PIPELINE_EXIT
