#!/usr/bin/env bash
# =============================================================================
# STAMINA-BIOME Confidence Threshold Sweep — lr_meta pipeline
#
# Sweeps Kraken2 confidence threshold (0.01, 0.02, 0.03, 0.05) on both
# vaginal and generic CAMISIM datasets using the new Langmead PlusPF database.
#
# Fixed parameters (proven invariant in bracken readlen sweep):
#   Bracken readlen    : 1200 bp
#   Min-hit-groups     : 1
#   Kraken2 DB         : PlusPF full (87 GB hash)
#
# Grid: 4 confidence × 2 datasets = 8 runs
#
# Resumable: already-completed runs are skipped automatically.
# No build phase required — kmer_distrib symlinks already in place.
#
# Usage:
#   ./sweep_confidence.sh                    # run all
#   ./sweep_confidence.sh --dataset generic  # only generic
#   ./sweep_confidence.sh --dataset vaginal  # only vaginal
#   ./sweep_confidence.sh --dry-run          # print plan, don't execute
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_RUNNER="${REPO_ROOT}/main/pipelines/run_in_container.sh"
WORK_DIR="${REPO_ROOT}/outputs"
VALIDATION_DIR="${REPO_ROOT}/validation"
CONFIG_DIR="${VALIDATION_DIR}/sweep_confidence_configs"
RESULTS_DIR="${VALIDATION_DIR}/sweep_results"
SCORES_TSV="${RESULTS_DIR}/scores_confidence.tsv"

# ── Dataset definitions ───────────────────────────────────────────────────────
GENERIC_FASTQ="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_generic/nanopore/sample.fastq"
GENERIC_GT="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_generic/nanopore/taxonomic_profile_0.txt"

VAGINAL_FASTQ="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_vaginal/nanopore/sample.fastq"
VAGINAL_GT="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_vaginal/nanopore/taxonomic_profile_0.txt"

# ── New PlusPF database ───────────────────────────────────────────────────────
KRAKEN2_DB="/Volumes/MyPassport/Kraken/kraken2/pluspf_full"

HUMAN_MMI="${REPO_ROOT}/main/data/reference/human/grch38/GRCh38.primary_assembly.genome.lowmem.mmi"
VALENCIA_CSV="${REPO_ROOT}/tools/VALENCIA/CST_centroids_012920.csv"

# ── Fixed sweep parameters ────────────────────────────────────────────────────
READLEN=1200
MHG=1
CONFIDENCE_VALUES=(0.01 0.02 0.03 0.05)
DATASETS=(generic vaginal)

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=0
DATASET_FILTER="all"

for arg in "$@"; do
  case "${arg}" in
    --dry-run)          DRY_RUN=1 ;;
    --dataset=generic)  DATASET_FILTER="generic" ;;
    --dataset=vaginal)  DATASET_FILTER="vaginal" ;;
    generic|vaginal)    DATASET_FILTER="${arg}" ;;
  esac
done

mkdir -p "${CONFIG_DIR}" "${RESULTS_DIR}"

# Write TSV header if scores file is new
if [[ ! -f "${SCORES_TSV}" ]]; then
  printf "run_id\tdataset\tconfidence\tmhg\treadlen\tMAE_pct\tspecies_detected\tspecies_total\trecovery_pct\tfalse_positives\n" \
    > "${SCORES_TSV}"
fi

# =============================================================================
# Config generation
# =============================================================================
make_config() {
  local run_id="$1"
  local fastq="$2"
  local confidence="$3"
  local specimen="$4"   # "vaginal" or "nonvaginal"
  local out="${CONFIG_DIR}/${run_id}.json"

  jq -n \
    --arg     run_id     "${run_id}" \
    --arg     work_dir   "${WORK_DIR}" \
    --arg     fastq      "${fastq}" \
    --arg     db         "${KRAKEN2_DB}" \
    --arg     human_mmi  "${HUMAN_MMI}" \
    --arg     valencia   "${VALENCIA_CSV}" \
    --arg     specimen   "${specimen}" \
    --argjson mhg        "${MHG}" \
    --argjson readlen    "${READLEN}" \
    --argjson confidence "${confidence}" \
    '{
      pipeline_id: "lr_meta",
      run: {
        work_dir: $work_dir,
        run_id:   $run_id,
        force_overwrite: 1,
        scope: "full"
      },
      technology: "ONT",
      specimen:   $specimen,
      input: { style: "FASTQ_SINGLE", fastq: $fastq },
      resources: { threads: 4 },
      params: {
        common: {
          min_qscore: 5, remove_host: 0, specimen: $specimen,
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
          vaginal:    { enabled: 1, readlen: $readlen },
          nonvaginal: { enabled: 1, readlen: $readlen }
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

# conf value → safe string for run ID (0.01→"001", 0.02→"002", etc.)
conf_str() {
  echo "$1" | sed 's/0\.//' | sed 's/\.//'
}

# =============================================================================
# Run one sweep point
# =============================================================================
run_point() {
  local dataset="$1"
  local confidence="$2"
  local fastq="$3"
  local ground_truth="$4"
  local specimen="$5"

  local cstr
  cstr="$(conf_str "${confidence}")"
  local run_id="csweep_${dataset}_conf${cstr}"
  local results_csv="${WORK_DIR}/${run_id}/results/tables/kraken_species_tidy.csv"

  # Skip if already completed
  if [[ -f "${results_csv}" ]]; then
    echo "[SKIP] ${run_id} — results already exist"
    bash "${VALIDATION_DIR}/score.sh" \
      "${results_csv}" "${ground_truth}" "${run_id}" "${dataset}" \
      "${confidence}" "${MHG}" "${SCORES_TSV}" "${READLEN}" 2>/dev/null || true
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo " RUN        : ${run_id}"
  echo " Dataset    : ${dataset}  |  Confidence: ${confidence}  |  MHG: ${MHG}  |  Readlen: ${READLEN}"
  echo " Specimen   : ${specimen}"
  echo " DB         : ${KRAKEN2_DB}"
  echo " FASTQ      : ${fastq}"
  echo "════════════════════════════════════════════════════════════════"

  local config
  config="$(make_config "${run_id}" "${fastq}" "${confidence}" "${specimen}")"
  echo " Config: ${config}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo " [DRY RUN] Would run: ${PIPELINE_RUNNER} --config ${config}"
    return 0
  fi

  # Verify DB is accessible
  if [[ ! -f "${KRAKEN2_DB}/hash.k2d" ]]; then
    echo " [ERROR] PlusPF database not found: ${KRAKEN2_DB}/hash.k2d"
    echo "         Is the external drive mounted?"
    exit 1
  fi

  local start elapsed ec=0
  start="$(date +%s)"
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
    "${confidence}" "${MHG}" "${SCORES_TSV}" "${READLEN}" || true
}

# =============================================================================
# Main sweep
# =============================================================================
echo "════════════════════════════════════════════════════════════════"
echo " STAMINA-BIOME Confidence Threshold Sweep"
echo " DB         : ${KRAKEN2_DB}"
echo " Confidence : ${CONFIDENCE_VALUES[*]}"
echo " Readlen    : ${READLEN} (fixed)   MHG: ${MHG} (fixed)"
echo " Datasets   : ${DATASET_FILTER}"
echo " Total runs : $((${#CONFIDENCE_VALUES[@]} * 2))"
echo " Run inside tmux/screen — each run ~2–6h on external USB drive"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo " [DRY RUN MODE — no pipelines will be executed]"
  echo ""
fi

total=0
done_count=0

for dataset in "${DATASETS[@]}"; do
  [[ "${DATASET_FILTER}" != "all" && "${DATASET_FILTER}" != "${dataset}" ]] && continue

  if [[ "${dataset}" == "generic" ]]; then
    fastq="${GENERIC_FASTQ}"
    gt="${GENERIC_GT}"
    specimen="nonvaginal"
  else
    fastq="${VAGINAL_FASTQ}"
    gt="${VAGINAL_GT}"
    specimen="vaginal"
  fi

  for confidence in "${CONFIDENCE_VALUES[@]}"; do
    total=$(( total + 1 ))
    run_point "${dataset}" "${confidence}" "${fastq}" "${gt}" "${specimen}"
    done_count=$(( done_count + 1 ))
    echo " Progress: ${done_count}/${total} planned so far"
  done
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Confidence sweep complete. Results:"
echo "════════════════════════════════════════════════════════════════"
if [[ -f "${SCORES_TSV}" ]]; then
  column -t "${SCORES_TSV}" 2>/dev/null || cat "${SCORES_TSV}"
fi
