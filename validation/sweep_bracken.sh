#!/usr/bin/env bash
# =============================================================================
# STAMINA-BIOME Bracken Parameter Sweep — lr_meta pipeline
#
# Phase 1 — Build Bracken kmer_distrib files for read lengths not yet present
#            in the Kraken2 DB:  500, 750, 1000, 1500, 2000
#            (1200 already exists from the original DB build)
#
# Phase 2 — Sweep:
#            readlen (500,750,1000,1200,1500,2000) × mhg (1,2) × dataset (generic,vaginal)
#            Confidence fixed at 0.01 (best from confidence sweep 1)
#            Bracken enabled for BOTH vaginal and non-vaginal
#
# Grid: 6 readlen × 2 mhg × 2 datasets = 24 runs
# Runtime: ~1h/length bracken-build (×5 new lengths) + ~2.5h/pipeline run (×24)
# Total estimate: ~65h. Run inside tmux/screen.
#
# Resumable: already-completed runs are skipped automatically.
# kmer_distrib files that already exist are not rebuilt.
#
# Data read length profile (CAMISIM generic ONT):
#   median=1418  mean=1474  p25=1114  p75=1772
# Bracken readlen should bracket this range.
#
# Usage:
#   ./sweep_bracken.sh                      # build + sweep all
#   ./sweep_bracken.sh --build-only         # only build kmer_distrib files
#   ./sweep_bracken.sh --skip-build         # skip build phase, go straight to sweep
#   ./sweep_bracken.sh --dataset generic    # only generic dataset
#   ./sweep_bracken.sh --dataset vaginal    # only vaginal dataset
#   ./sweep_bracken.sh --dry-run            # print what would run, don't execute
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_RUNNER="${REPO_ROOT}/main/pipelines/run_in_container.sh"
WORK_DIR="${REPO_ROOT}/outputs"
VALIDATION_DIR="${REPO_ROOT}/validation"
CONFIG_DIR="${VALIDATION_DIR}/sweep_bracken_configs"
RESULTS_DIR="${VALIDATION_DIR}/sweep_results"
SCORES_TSV="${RESULTS_DIR}/scores_bracken.tsv"

# ── Dataset definitions ───────────────────────────────────────────────────────
GENERIC_FASTQ="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_generic/nanopore/sample.fastq"
GENERIC_GT="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_generic/nanopore/taxonomic_profile_0.txt"

VAGINAL_FASTQ="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_vaginal/nanopore/sample.fastq"
VAGINAL_GT="/Users/izzydavidson/Desktop/camisim_output/mock_metagenome_vaginal/nanopore/taxonomic_profile_0.txt"

KRAKEN2_DB="/Volumes/MyPassport/Kraken/kraken2/core_nt/_old_build_20260116_060100"
KRAKEN2_DB_PARENT="/Volumes/MyPassport/Kraken/kraken2/core_nt"
KRAKEN2_DB_SUBDIR="_old_build_20260116_060100"
HUMAN_MMI="${REPO_ROOT}/main/data/reference/human/grch38/GRCh38.primary_assembly.genome.lowmem.mmi"
VALENCIA_CSV="${REPO_ROOT}/tools/VALENCIA/CST_centroids_012920.csv"
DOCKER_IMAGE="stamina-biome-tools-lr:dev"

# ── Sweep grid ────────────────────────────────────────────────────────────────
CONFIDENCE="0.01"               # fixed — best from confidence sweep 1
READLEN_VALUES=(500 750 1000 1200 1500 2000)
MHG_VALUES=(1 2)
DATASETS=(generic vaginal)

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=0
BUILD_ONLY=0
SKIP_BUILD=0
DATASET_FILTER="all"

for arg in "$@"; do
  case "${arg}" in
    --dry-run)          DRY_RUN=1 ;;
    --build-only)       BUILD_ONLY=1 ;;
    --skip-build)       SKIP_BUILD=1 ;;
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
# Phase 1: Build Bracken kmer_distrib files
# =============================================================================
build_bracken_dist() {
  local readlen="$1"
  local distfile="${KRAKEN2_DB}/database${readlen}mers.kmer_distrib"

  if [[ -f "${distfile}" ]]; then
    echo "[bracken-build] readlen=${readlen}: already exists — skipping"
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo " Building Bracken distribution: readlen=${readlen}"
  echo " Output will be: ${distfile}"
  echo " NOTE: reads the full Kraken2 DB hash — expect ~1h on USB drive"
  echo "════════════════════════════════════════════════════════════════"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo " [DRY RUN] Would run bracken-build -d /db_root/${KRAKEN2_DB_SUBDIR} -l ${readlen} -t 8 -k 35"
    return 0
  fi

  if [[ ! -d "${KRAKEN2_DB}" ]]; then
    echo " [ERROR] Kraken2 DB not found at: ${KRAKEN2_DB}"
    echo "         Is the external drive mounted?"
    return 1
  fi

  # bracken-build needs library/, taxonomy/, and seqid2taxid.map in the same
  # directory as hash.k2d. These live in the parent; create relative symlinks
  # so they resolve correctly both inside Docker and on the host.
  for target in library taxonomy seqid2taxid.map; do
    link="${KRAKEN2_DB}/${target}"
    if [[ ! -e "${link}" ]]; then
      ln -sf "../${target}" "${link}"
      echo " [setup] Created symlink: ${link} -> ../${target}"
    fi
  done

  local start elapsed ec=0
  start="$(date +%s)"

  # Mount parent dir so symlinks resolve inside the container.
  # bracken-build needs kmer2read_distr compiled — install g++ and build it first.
  docker run --rm \
    -v "${KRAKEN2_DB_PARENT}:/db_root" \
    "${DOCKER_IMAGE}" \
    bash -c "
      apt-get update -q 2>/dev/null &&
      apt-get install -y -q g++ make 2>/dev/null &&
      cd /opt/bracken/src && make -s CXX=g++ &&
      /opt/bracken/bracken-build \
        -d /db_root/${KRAKEN2_DB_SUBDIR} \
        -l ${readlen} \
        -t 8 \
        -k 35
    " || ec=$?

  elapsed=$(( $(date +%s) - start ))
  printf " bracken-build readlen=%d finished in %dm %ds (exit=%d)\n" \
    "${readlen}" $((elapsed/60)) $((elapsed%60)) "${ec}"

  if [[ "${ec}" -ne 0 ]]; then
    echo " [ERROR] bracken-build failed for readlen=${readlen}"
    return 1
  fi

  if [[ ! -f "${distfile}" ]]; then
    echo " [ERROR] Expected output not found: ${distfile}"
    return 1
  fi

  echo " [OK] ${distfile}"
}

# =============================================================================
# Config generation
# =============================================================================
make_config() {
  local run_id="$1"
  local fastq="$2"
  local readlen="$3"
  local mhg="$4"
  local specimen="$5"   # "vaginal" or "nonvaginal"
  local out="${CONFIG_DIR}/${run_id}.json"

  jq -n \
    --arg  run_id    "${run_id}" \
    --arg  work_dir  "${WORK_DIR}" \
    --arg  fastq     "${fastq}" \
    --arg  db        "${KRAKEN2_DB}" \
    --arg  human_mmi "${HUMAN_MMI}" \
    --arg  valencia  "${VALENCIA_CSV}" \
    --arg  specimen  "${specimen}" \
    --argjson mhg     "${mhg}" \
    --argjson readlen "${readlen}" \
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
          vaginal:    { confidence: 0.01, minimum_hit_groups: $mhg },
          nonvaginal: { confidence: 0.01, minimum_hit_groups: $mhg }
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

# =============================================================================
# Run one sweep point
# =============================================================================
run_point() {
  local dataset="$1"
  local run_id="$2"
  local readlen="$3"
  local mhg="$4"
  local fastq="$5"
  local ground_truth="$6"
  local specimen="$7"

  local results_csv="${WORK_DIR}/${run_id}/results/tables/kraken_species_tidy.csv"

  # Skip if already completed
  if [[ -f "${results_csv}" ]]; then
    echo "[SKIP] ${run_id} — results already exist"
    bash "${VALIDATION_DIR}/score.sh" \
      "${results_csv}" "${ground_truth}" "${run_id}" "${dataset}" \
      "${CONFIDENCE}" "${mhg}" "${SCORES_TSV}" "${readlen}" 2>/dev/null || true
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo " RUN      : ${run_id}"
  echo " Dataset  : ${dataset}  |  MHG: ${mhg}  |  Readlen: ${readlen}  |  Conf: ${CONFIDENCE}"
  echo " Specimen : ${specimen}"
  echo " FASTQ    : ${fastq}"
  echo "════════════════════════════════════════════════════════════════"

  local config
  config="$(make_config "${run_id}" "${fastq}" "${readlen}" "${mhg}" "${specimen}")"
  echo " Config: ${config}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo " [DRY RUN] Would run: ${PIPELINE_RUNNER} --config ${config}"
    return 0
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
    "${CONFIDENCE}" "${mhg}" "${SCORES_TSV}" "${readlen}" || true
}

# =============================================================================
# Phase 1: Build kmer_distrib files
# =============================================================================
if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  echo "STAMINA-BIOME Bracken Sweep — Phase 1: Building kmer_distrib files"
  echo "Lengths to check: ${READLEN_VALUES[*]}"
  echo ""

  for rl in "${READLEN_VALUES[@]}"; do
    build_bracken_dist "${rl}" || {
      echo ""
      echo "[FATAL] bracken-build failed for readlen=${rl}. Cannot continue sweep."
      echo "        Fix the error above, then rerun with --skip-build to resume from Phase 2."
      exit 1
    }
  done

  echo ""
  echo "All kmer_distrib files ready."
fi

if [[ "${BUILD_ONLY}" -eq 1 ]]; then
  echo ""
  echo "Build-only mode — done."
  exit 0
fi

# =============================================================================
# Phase 2: Sweep
# =============================================================================
echo ""
echo "STAMINA-BIOME Bracken Sweep — Phase 2: Parameter Sweep"
echo "Confidence: ${CONFIDENCE} (fixed)  |  Bracken enabled: YES (both specimen types)"
echo "ReadLens: ${READLEN_VALUES[*]}"
echo "MHG: ${MHG_VALUES[*]}  |  Datasets: ${DATASET_FILTER}"
total_runs=$(( ${#READLEN_VALUES[@]} * ${#MHG_VALUES[@]} * 2 ))
echo "Total planned: ${total_runs} runs  (~$(( total_runs * 5 / 2 ))h estimated)"
echo "Run inside tmux/screen. Resumable — completed runs are skipped."
echo ""

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

  for readlen in "${READLEN_VALUES[@]}"; do
    # Verify the kmer_distrib file exists before running
    distfile="${KRAKEN2_DB}/database${readlen}mers.kmer_distrib"
    if [[ ! -f "${distfile}" && "${DRY_RUN}" -eq 0 ]]; then
      echo "[WARN] kmer_distrib not found for readlen=${readlen}: ${distfile}"
      echo "       Run without --skip-build to build it first. Skipping readlen=${readlen}."
      continue
    fi

    for mhg in "${MHG_VALUES[@]}"; do
      run_id="bsweep_${dataset}_rl${readlen}_mhg${mhg}"
      total=$(( total + 1 ))

      run_point "${dataset}" "${run_id}" "${readlen}" "${mhg}" "${fastq}" "${gt}" "${specimen}"
      done_count=$(( done_count + 1 ))

      echo " Progress: ${done_count}/${total} planned so far"
    done
  done
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Bracken sweep complete. Summary:"
echo "════════════════════════════════════════════════════════════════"
if [[ -f "${SCORES_TSV}" ]]; then
  column -t "${SCORES_TSV}" 2>/dev/null || cat "${SCORES_TSV}"
fi
