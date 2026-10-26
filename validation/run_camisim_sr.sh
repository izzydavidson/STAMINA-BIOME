#!/usr/bin/env bash
# validation/run_camisim_sr.sh
# Run CAMISIM short-read (Illumina/ART) simulations for all 4 STAMINA-BIOME body sites.
#
# Uses the Nextflow CAMISIM pipeline (~/CAMISIM/main.nf) with --type art.
# Reuses the same genome configs as the LR runs.
#
# Read parameters (from CAMISIM art.config — ART_MBARC-26_HiSeq_R bundled profile):
#   Read length:   150 bp PE (PE150)
#   Fragment size: 270 bp mean, 27 bp SD
#   Total output:  5 Gbp per community (~16.7M read pairs)
#
# Output per site (same location as LR datasets):
#   ~/camisim_output/{site}_sr/sample_0/reads/fastq/sample_0_01.fq.gz  (R1)
#   ~/camisim_output/{site}_sr/sample_0/reads/fastq/sample_0_02.fq.gz  (R2)
# Work dir (intermediates only — 30-35 GB per site) goes to MyPassport to avoid filling local SSD.
#
# Usage:
#   bash validation/run_camisim_sr.sh [--sites vaginal,gut,oral,skin] [--size 5.0]

set -euo pipefail

# Nextflow requires Java 17+. The system default (Apple Java 8) is too old.
# Use the JVM bundled with miniforge3 (Java 23).
export JAVA_HOME="${HOME}/miniforge3/lib/jvm"
export PATH="${JAVA_HOME}/bin:${PATH}"

# Nextflow process wrappers call `conda activate` — conda must be on PATH.
# Non-interactive shells do not source ~/.zshrc so we initialise it explicitly.
# shellcheck disable=SC1091
source "${HOME}/miniforge3/etc/profile.d/conda.sh"
conda activate base 2>/dev/null || true   # ensure conda base is active

NEXTFLOW="${HOME}/miniforge3/bin/nextflow"
CAMISIM_DIR="${HOME}/CAMISIM"
CONFIG_BASE="${HOME}/camisim_configs"
LOCAL_BASE="${HOME}/camisim_output"                # final destination for merged fastqs
OUTPUT_BASE="/Volumes/MyPassport/camisim_output"   # full Nextflow outdir (BAMs ~12 GB/site) on MyPassport
WORK_BASE="/Volumes/MyPassport/camisim_work"       # Nextflow work cache on MyPassport
TAXDUMP="${HOME}/camisim_genomes/ncbi_taxonomy/taxdump.tar.gz"
SITES=(vaginal gut oral skin)
SIZE=5.0   # Gbp — yields ~16.7M PE150 read pairs per community

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sites) IFS=',' read -ra SITES <<< "$2"; shift 2 ;;
    --size)  SIZE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }

if [[ ! -x "$NEXTFLOW" ]]; then
  echo "[FATAL] nextflow not found at $NEXTFLOW"
  exit 1
fi

if [[ ! -f "${CAMISIM_DIR}/main.nf" ]]; then
  echo "[FATAL] CAMISIM main.nf not found at ${CAMISIM_DIR}/main.nf"
  exit 1
fi

log "=== STAMINA-BIOME CAMISIM Short-Read (Illumina ART PE150) Simulation ==="
log "Sites:    ${SITES[*]}"
log "Size:     ${SIZE} Gbp per community (~$(echo "scale=0; $SIZE * 1000 / 150 / 1000" | bc)M read pairs)"
log "Profile:  ART_MBARC-26_HiSeq_R PE150, fragment 270bp/27bp SD"
log "CAMISIM:  ${CAMISIM_DIR}"
log ""

FAILED=()
for site in "${SITES[@]}"; do
  cfg="${CONFIG_BASE}/${site}"   # reuse LR genome configs
  outdir="${OUTPUT_BASE}/${site}_sr"
  workdir="${WORK_BASE}/${site}_sr"
  logfile="${outdir}/nf_${site}_sr.log"

  log "━━━ Site: ${site^^} ━━━"

  for f in genome_locations.tsv meta_data.tsv distribution_0.txt; do
    if [[ ! -f "${cfg}/${f}" ]]; then
      log "  [ERROR] Missing config file: ${cfg}/${f}"; FAILED+=("$site"); continue 2
    fi
  done

  # Check if merged fastqs already exist at the final local destination
  local_r1="${LOCAL_BASE}/${site}_sr/sample_0/reads/fastq/sample_0_01.fq.gz"
  local_r2="${LOCAL_BASE}/${site}_sr/sample_0/reads/fastq/sample_0_02.fq.gz"
  if [[ -f "$local_r1" && -f "$local_r2" ]]; then
    sz1=$(stat -f%z "$local_r1" 2>/dev/null || stat -c%s "$local_r1")
    sz2=$(stat -f%z "$local_r2" 2>/dev/null || stat -c%s "$local_r2")
    log "  [SKIP] Already at local destination: R1=$(( sz1/1024/1024 ))MB  R2=$(( sz2/1024/1024 ))MB"
    continue
  fi

  r1="${outdir}/sample_0/reads/fastq/sample_0_01.fq.gz"
  r2="${outdir}/sample_0/reads/fastq/sample_0_02.fq.gz"

  mkdir -p "$outdir" "$workdir"

  log "  Output:   ${outdir}/sample_0/reads/fastq/"
  log "  Log:      ${logfile}"

  # Skin has 9 genomes; concurrent NTFS writes from all 9 ART tasks causes gzip
  # "No space left on device" errors even when disk has space. Limit to 2 concurrent tasks.
  EXTRA_CONFIG=""
  if [[ "$site" == "skin" ]]; then
    EXTRA_CONFIG="-c /private/tmp/claude-501/-Users-izzydavidson/65d703bc-e3de-4392-94a1-c3fb7464e563/scratchpad/skin_maxforks.config"
  fi

  t0=$(date +%s)
  if (cd "${CAMISIM_DIR}" && "$NEXTFLOW" run main.nf \
      --type art \
      --size "${SIZE}" \
      --number_of_samples 1 \
      --genome_locations_file "${cfg}/genome_locations.tsv" \
      --metadata_file "${cfg}/meta_data.tsv" \
      --distribution_files "${cfg}/distribution_0.txt" \
      --ncbi_taxdump_file "${TAXDUMP}" \
      --outdir "${outdir}" \
      --gsa true \
      --pooled_gsa true \
      --anonymization false \
      --max_strains_per_otu 1 \
      -work-dir "${workdir}" \
      -resume \
      ${EXTRA_CONFIG} \
      2>&1 | tee "${logfile}"); then
    t1=$(date +%s)
    log "  ✓ ${site^^} done in $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"
    if [[ -f "$r1" && -f "$r2" ]]; then
      # Copy only the merged fastqs to the local destination
      mkdir -p "${LOCAL_BASE}/${site}_sr/sample_0/reads/fastq/"
      cp "$r1" "$local_r1"
      cp "$r2" "$local_r2"
      sz1=$(stat -f%z "$local_r1" 2>/dev/null || stat -c%s "$local_r1")
      sz2=$(stat -f%z "$local_r2" 2>/dev/null || stat -c%s "$local_r2")
      log "  R1: $local_r1 ($(( sz1/1024/1024 )) MB)"
      log "  R2: $local_r2 ($(( sz2/1024/1024 )) MB)"
    else
      log "  [WARN] R1/R2 not found on MyPassport — check $logfile"
    fi
  else
    t1=$(date +%s)
    log "  [ERROR] Nextflow failed for $site — see $logfile"
    FAILED+=("$site")
  fi
  log ""
done

log "=== SR CAMISIM Complete ==="
if [[ ${#FAILED[@]} -eq 0 ]]; then
  log "All sites done: ${SITES[*]}"
  log ""
  log "SR FASTQ outputs (use these as input to stamina-biome SR pipeline):"
  for site in "${SITES[@]}"; do
    r1="${LOCAL_BASE}/${site}_sr/sample_0/reads/fastq/sample_0_01.fq.gz"
    r2="${LOCAL_BASE}/${site}_sr/sample_0/reads/fastq/sample_0_02.fq.gz"
    [[ -f "$r1" ]] && log "  ✓ ${site} R1: $r1" || log "  ✗ ${site} R1: $r1 (missing)"
    [[ -f "$r2" ]] && log "  ✓ ${site} R2: $r2" || log "  ✗ ${site} R2: $r2 (missing)"
  done
  exit 0
else
  log "[WARN] Failed sites: ${FAILED[*]}"
  exit 1
fi
