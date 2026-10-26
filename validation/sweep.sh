#!/usr/bin/env bash
# =============================================================================
# STAMINA-BIOME Parameter Sweep — lr_meta pipeline
#
# Sweeps Kraken2 confidence (0.01–0.10 in 0.01 steps) × min_hit_groups (1,2)
# for BOTH the generic and vaginal CAMISIM mock datasets.
#
# Total runs: 10 confidence × 2 mhg × 2 datasets = 40 runs
# Estimated runtime: ~2.5h per run on USB DB → ~100h total. Use tmux/screen.
#
# Resumable: already-completed runs are skipped automatically.
#
# Usage:
#   ./sweep.sh --db /path/to/kraken2/db \
#              --generic-fastq /path/to/generic.fastq --generic-gt /path/to/generic_gt.txt \
#              --vaginal-fastq /path/to/vaginal.fastq --vaginal-gt /path/to/vaginal_gt.txt
#   ./sweep.sh ... --dataset generic    # only generic dataset
#   ./sweep.sh ... --dataset vaginal    # only vaginal dataset
#   ./sweep.sh ... --dry-run            # print what would run, don't execute
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_RUNNER="${REPO_ROOT}/main/pipelines/run_in_container.sh"
WORK_DIR="${REPO_ROOT}/outputs"
VALIDATION_DIR="${REPO_ROOT}/validation"
CONFIG_DIR="${VALIDATION_DIR}/sweep_configs"
RESULTS_DIR="${VALIDATION_DIR}/sweep_results"
SCORES_TSV="${RESULTS_DIR}/scores.tsv"

# ── Dataset definitions (override with --generic-fastq, --vaginal-fastq, --db) ──
GENERIC_FASTQ=""
GENERIC_GT=""
VAGINAL_FASTQ=""
VAGINAL_GT=""
KRAKEN2_DB=""
HUMAN_MMI="${REPO_ROOT}/main/data/reference/human/grch38/GRCh38.primary_assembly.genome.lowmem.mmi"
VALENCIA_CSV="${REPO_ROOT}/tools/VALENCIA/CST_centroids_012920.csv"

# ── Sweep grid ────────────────────────────────────────────────────────────────
# confidence: 0.01 to 0.10 in 0.01 steps (represented as integers 1..10)
CONFIDENCE_INTS=(1 2 3 4 5 6 7 8 9 10)
MHG_VALUES=(1 2)
DATASETS=(generic vaginal)

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=0
DATASET_FILTER="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)             DRY_RUN=1; shift ;;
    --dataset)             DATASET_FILTER="$2"; shift 2 ;;
    --dataset=*)           DATASET_FILTER="${1#*=}"; shift ;;
    generic|vaginal)       DATASET_FILTER="$1"; shift ;;
    --generic-fastq)       GENERIC_FASTQ="$2"; shift 2 ;;
    --generic-gt)          GENERIC_GT="$2"; shift 2 ;;
    --vaginal-fastq)       VAGINAL_FASTQ="$2"; shift 2 ;;
    --vaginal-gt)          VAGINAL_GT="$2"; shift 2 ;;
    --db)                  KRAKEN2_DB="$2"; shift 2 ;;
    --human-mmi)           HUMAN_MMI="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required paths
if [[ -z "$KRAKEN2_DB" ]]; then
  echo "Error: --db <kraken2_db_path> is required"
  echo "Usage: ./sweep.sh --db /path/to/kraken2/db [--generic-fastq ...] [--vaginal-fastq ...]"
  exit 1
fi
if [[ -z "$GENERIC_FASTQ" || -z "$VAGINAL_FASTQ" ]]; then
  echo "Error: --generic-fastq and --vaginal-fastq are required"
  exit 1
fi
if [[ -z "$GENERIC_GT" || -z "$VAGINAL_GT" ]]; then
  echo "Error: --generic-gt and --vaginal-gt (ground truth TSV paths) are required"
  exit 1
fi

mkdir -p "${CONFIG_DIR}" "${RESULTS_DIR}"

# Write TSV header if scores file is new
if [[ ! -f "${SCORES_TSV}" ]]; then
  printf "run_id\tdataset\tconfidence\tmhg\tMAE_pct\tspecies_detected\tspecies_total\trecovery_pct\tfalse_positives\n" \
    > "${SCORES_TSV}"
fi

# ── Generate config JSON ──────────────────────────────────────────────────────
make_config() {
  local run_id="$1"
  local fastq="$2"
  local confidence="$3"
  local mhg="$4"
  local out="${CONFIG_DIR}/${run_id}.json"

  jq -n \
    --arg  run_id     "${run_id}" \
    --arg  work_dir   "${WORK_DIR}" \
    --arg  fastq      "${fastq}" \
    --arg  db         "${KRAKEN2_DB}" \
    --arg  human_mmi  "${HUMAN_MMI}" \
    --arg  valencia   "${VALENCIA_CSV}" \
    --argjson confidence "${confidence}" \
    --argjson mhg         "${mhg}" \
    '{
      pipeline_id: "lr_meta",
      run: {
        work_dir: $work_dir,
        run_id:   $run_id,
        force_overwrite: 1,
        scope: "full"
      },
      technology: "ONT",
      specimen:   "vaginal",
      input: { style: "FASTQ_SINGLE", fastq: $fastq },
      resources: { threads: 4 },
      params: {
        common: {
          min_qscore: 5, remove_host: 0, specimen: "vaginal",
          trim_adapter: true, demultiplex: false
        },
        seq_type: "map-ont"
      },
      tools: {
        qfilter:  { enabled: 1, min_q: 5, min_len: 1000 },
        kraken2: {
          db: $db,
          vaginal:    { confidence: $confidence, minimum_hit_groups: $mhg },
          nonvaginal: { confidence: $confidence, minimum_hit_groups: $mhg }
        },
        bracken: {
          vaginal:    { enabled: 1, readlen: 1200 },
          nonvaginal: { enabled: 0, readlen: 1200 }
        },
        minimap2: { human_mmi: $human_mmi, split_prefix: 0 }
      },
      output: {
        selected: ["raw_csv","pie_chart","heatmap","stacked_bar","quality_reports"]
      },
      postprocess: {
        enabled: 1,
        steps: {
          heatmap: 1, piechart: 1, stacked_bar: 1,
          results_csv: 1, relative_abundance: 0, valencia: 1
        }
      },
      valencia: { enabled: 1, mode: "auto", centroids_csv: $valencia }
    }' > "${out}"

  echo "${out}"
}

# ── Run one sweep point ───────────────────────────────────────────────────────
run_point() {
  local dataset="$1"
  local run_id="$2"
  local confidence="$3"
  local mhg="$4"
  local fastq="$5"
  local ground_truth="$6"

  local results_csv="${WORK_DIR}/${run_id}/results/tables/kraken_species_tidy.csv"

  # Skip if already completed
  if [[ -f "${results_csv}" ]]; then
    echo "[SKIP] ${run_id} — results already exist"
    # Still score it in case it wasn't scored yet
    bash "${VALIDATION_DIR}/score.sh" \
      "${results_csv}" "${ground_truth}" "${run_id}" "${dataset}" \
      "${confidence}" "${mhg}" "${SCORES_TSV}" 2>/dev/null || true
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo " RUN  : ${run_id}"
  echo " Dataset    : ${dataset}"
  echo " Confidence : ${confidence}"
  echo " MHG        : ${mhg}"
  echo " FASTQ      : ${fastq}"
  echo "════════════════════════════════════════════════════════════════"

  local config
  config="$(make_config "${run_id}" "${fastq}" "${confidence}" "${mhg}")"
  echo " Config: ${config}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo " [DRY RUN] Would run: ${PIPELINE_RUNNER} --config ${config}"
    return 0
  fi

  local start elapsed
  start="$(date +%s)"

  # Run pipeline — capture exit code without aborting the sweep
  local ec=0
  "${PIPELINE_RUNNER}" --config "${config}" || ec=$?

  elapsed=$(( $(date +%s) - start ))
  printf " Finished in %dm %ds (exit=%d)\n" $((elapsed/60)) $((elapsed%60)) "${ec}"

  if [[ "${ec}" -ne 0 ]]; then
    echo " [WARN] Pipeline exited with code ${ec} — skipping score for ${run_id}"
    return 0
  fi

  if [[ ! -f "${results_csv}" ]]; then
    echo " [WARN] Results CSV not found at ${results_csv} — skipping score"
    return 0
  fi

  echo " Scoring..."
  bash "${VALIDATION_DIR}/score.sh" \
    "${results_csv}" "${ground_truth}" "${run_id}" "${dataset}" \
    "${confidence}" "${mhg}" "${SCORES_TSV}" || true
}

# ── Main sweep loop ───────────────────────────────────────────────────────────
echo "STAMINA-BIOME lr_meta Parameter Sweep"
echo "Confidence: 0.01 → 0.10  |  MHG: 1, 2  |  Datasets: ${DATASET_FILTER}"
echo "Estimated runtime: ~2.5h per run. Run inside tmux/screen."
echo ""

total=0
done_count=0

for dataset in "${DATASETS[@]}"; do
  [[ "${DATASET_FILTER}" != "all" && "${DATASET_FILTER}" != "${dataset}" ]] && continue

  if [[ "${dataset}" == "generic" ]]; then
    fastq="${GENERIC_FASTQ}"
    gt="${GENERIC_GT}"
  else
    fastq="${VAGINAL_FASTQ}"
    gt="${VAGINAL_GT}"
  fi

  for c_int in "${CONFIDENCE_INTS[@]}"; do
    confidence="$(printf "0.%02d" "${c_int}")"
    c_tag="$(printf "%03d" "${c_int}")"

    for mhg in "${MHG_VALUES[@]}"; do
      run_id="sweep_${dataset}_c${c_tag}_mhg${mhg}"
      total=$(( total + 1 ))

      run_point "${dataset}" "${run_id}" "${confidence}" "${mhg}" "${fastq}" "${gt}"
      done_count=$(( done_count + 1 ))

      echo " Progress: ${done_count}/${total} planned so far"
    done
  done
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Sweep complete. Summary:"
echo "════════════════════════════════════════════════════════════════"
if [[ -f "${SCORES_TSV}" ]]; then
  column -t "${SCORES_TSV}" 2>/dev/null || cat "${SCORES_TSV}"
fi
