#!/usr/bin/env bash
# validation/run_stamina_biome_meta_camisim.sh
# Run 8 STAMINA-BIOME meta pipeline runs on CAMISIM mock data (4 LR + 4 SR).
#
# Settings for all runs:
#   - Q10 quality filter
#   - No minimum read length
#   - No host depletion
#   - Custom Kraken2 databases (/Volumes/MyPassport/custom_db/{site}/)
#   - Kraken2 confidence and min_hit_groups per site (see table below)
#   - LR: lr_meta pipeline (barcode_kit not passed; input is already FASTQ)
#   - SR: sr_meta pipeline
#
# Site-specific Kraken2 params:
#   vaginal  confidence=0.02  min_hit_groups=2
#   gut      confidence=0.03  min_hit_groups=4
#   oral     confidence=0.04  min_hit_groups=4
#   skin     confidence=0.03  min_hit_groups=4

set -euo pipefail

REPO="/Users/izzydavidson/Desktop/STAMINA-BIOME"
PYTHON3="python3"
CAMISIM_BASE="/Volumes/MyPassport/CAMISIM/camisim_output_sr"
DB_BASE="/Volumes/MyPassport/custom_db"
OUTDIR="${HOME}/Desktop/STAMINA-BIOME_CAMISIM_validation"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Site-specific Kraken2 params arrays
declare -A CONF=([vaginal]="0.02" [gut]="0.03" [oral]="0.04" [skin]="0.03")
declare -A MHG=([vaginal]="2"    [gut]="4"    [oral]="4"    [skin]="4")

FAILED=()
PASSED=()

run_stamina_biome() {
  local pipeline="$1" site="$2" run_label="$3"
  shift 3
  local input_args=("$@")

  local db="${DB_BASE}/${site}"
  local outrun="${OUTDIR}/${run_label}"
  local logfile="${OUTDIR}/logs/${run_label}.log"
  mkdir -p "${OUTDIR}/logs"

  # Validate inputs
  for f in "${input_args[@]}"; do
    if [[ ! -f "$f" ]]; then
      log "  [ERROR] Input not found: $f"
      FAILED+=("${run_label}")
      return 1
    fi
  done
  if [[ ! -d "$db" ]]; then
    log "  [ERROR] Kraken2 DB not found: $db"
    FAILED+=("${run_label}")
    return 1
  fi

  # Bracken re-estimation read length (bp): must match a database{N}mers.kmer_distrib
  # file present in the DB. LR reads are near-full-length (~1500bp); SR reads are PE150.
  local bracken_readlen
  if [[ "${pipeline}" == lr_* ]]; then
    bracken_readlen="1500"
  else
    bracken_readlen="150"
  fi

  log "━━━ ${run_label} ━━━"
  log "  Pipeline:    ${pipeline}"
  log "  Site:        ${site}"
  log "  Input:       ${input_args[*]}"
  log "  DB:          ${db}"
  log "  Confidence:  ${CONF[$site]}   Min-hit-groups: ${MHG[$site]}"
  log "  Bracken:     readlen=${bracken_readlen}"
  log "  Output:      ${outrun}"
  log "  Log:         ${logfile}"

  local t0
  t0=$(date +%s)

  if (cd "${REPO}" && "${PYTHON3}" -m cli run \
      --pipeline "${pipeline}" \
      --input "${input_args[@]}" \
      --sample-type "${site}" \
      --db "${db}" \
      --kraken-confidence "${CONF[$site]}" \
      --kraken-min-hit-groups "${MHG[$site]}" \
      --bracken-readlen "${bracken_readlen}" \
      --min-qscore 10 \
      --outdir "${OUTDIR}" \
      --run-id "${run_label}" \
      --force \
      2>&1 | tee "${logfile}"); then
    local t1
    t1=$(date +%s)
    log "  ✓ ${run_label} done in $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"
    PASSED+=("${run_label}")
  else
    local t1
    t1=$(date +%s)
    log "  [ERROR] ${run_label} failed after $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s — see ${logfile}"
    FAILED+=("${run_label}")
  fi
  log ""
}

mkdir -p "${OUTDIR}"
log "=== STAMINA-BIOME CAMISIM Meta Validation ==="
log "Output base: ${OUTDIR}"
log ""

# ── Long-read (lr_meta) ──────────────────────────────────────────────────────
for site in vaginal gut oral skin; do
  fq="${CAMISIM_BASE}/mock_metagenome_${site}/nanopore/sample_0/reads/fastq/sample_0.fq.gz"
  run_stamina_biome "lr_meta" "${site}" "lr_meta_${site}" "${fq}"
done

# ── Short-read (sr_meta) ─────────────────────────────────────────────────────
for site in vaginal gut oral skin; do
  r1="${CAMISIM_BASE}/${site}_sr/sample_0/reads/fastq/sample_0_01.fq.gz"
  r2="${CAMISIM_BASE}/${site}_sr/sample_0/reads/fastq/sample_0_02.fq.gz"
  run_stamina_biome "sr_meta" "${site}" "sr_meta_${site}" "${r1}" "${r2}"
done

# ── Summary ──────────────────────────────────────────────────────────────────
log "=== Run Summary ==="
log "Passed (${#PASSED[@]}): ${PASSED[*]:-none}"
log "Failed (${#FAILED[@]}): ${FAILED[*]:-none}"
log ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
  log "All 8 runs completed successfully."
  log "Results: ${OUTDIR}/"
  exit 0
else
  log "[WARN] ${#FAILED[@]} run(s) failed. Check logs in ${OUTDIR}/logs/"
  exit 1
fi
