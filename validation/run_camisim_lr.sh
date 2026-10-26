#!/usr/bin/env bash
# validation/run_camisim_lr.sh
# Run CAMISIM long-read (NanoSim3/ONT) simulations for vaginal and gut body sites.
#
# Uses the same Nextflow CAMISIM pipeline and parameters as the existing
# oral and skin datasets (confirmed from ~/.nextflow.log archive).
#
# Command pattern (from CAMISIM/.nextflow.log — oral run 27-Mar-2026):
#   cd ~/CAMISIM && nextflow run main.nf --type nanosim3 --size 0.5
#     --distribution_files ... --ncbi_taxdump_file ... -work-dir ...
#
# Output:
#   ~/camisim_output/mock_metagenome_{site}/nanopore/sample_0/reads/fastq/sample_0.fq.gz
#
# Usage:
#   bash validation/run_camisim_lr.sh [--sites vaginal,gut] [--size 0.5]

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
OUTPUT_BASE="${HOME}/camisim_output"
TAXDUMP="${HOME}/camisim_genomes/ncbi_taxonomy/taxdump.tar.gz"
SITES=(vaginal gut)
SIZE=0.5   # Gbp — matches existing oral/skin runs (~500 Mbp, ~1417 bp mean read length)

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

log "=== STAMINA-BIOME CAMISIM Long-Read (NanoSim3/ONT) Simulation ==="
log "Sites:    ${SITES[*]}"
log "Size:     ${SIZE} Gbp per community"
log "CAMISIM:  ${CAMISIM_DIR}"
log ""

FAILED=()
for site in "${SITES[@]}"; do
  cfg="${CONFIG_BASE}/${site}"
  outdir="${OUTPUT_BASE}/mock_metagenome_${site}"
  nanopore_out="${outdir}/nanopore"
  workdir="${outdir}/nanopore_work"
  logfile="${outdir}/nf_${site}.log"

  log "━━━ Site: ${site^^} ━━━"

  for f in genome_locations.tsv meta_data.tsv distribution_0.txt; do
    if [[ ! -f "${cfg}/${f}" ]]; then
      log "  [ERROR] Missing config file: ${cfg}/${f}"; FAILED+=("$site"); continue 2
    fi
  done

  if [[ -f "${nanopore_out}/sample_0/reads/fastq/sample_0.fq.gz" ]]; then
    sz=$(stat -f%z "${nanopore_out}/sample_0/reads/fastq/sample_0.fq.gz" 2>/dev/null || \
         stat -c%s  "${nanopore_out}/sample_0/reads/fastq/sample_0.fq.gz")
    log "  [SKIP] Already exists ($(( sz/1024/1024 )) MB)"
    continue
  fi

  mkdir -p "$outdir" "$nanopore_out" "$workdir"

  log "  Output:   ${nanopore_out}/sample_0/reads/fastq/sample_0.fq.gz"
  log "  Log:      ${logfile}"

  t0=$(date +%s)
  # Must run from CAMISIM_DIR so relative paths in NF scripts resolve correctly
  if (cd "${CAMISIM_DIR}" && "$NEXTFLOW" run main.nf \
      --type nanosim3 \
      --size "${SIZE}" \
      --number_of_samples 1 \
      --genome_locations_file "${cfg}/genome_locations.tsv" \
      --metadata_file "${cfg}/meta_data.tsv" \
      --distribution_files "${cfg}/distribution_0.txt" \
      --ncbi_taxdump_file "${TAXDUMP}" \
      --outdir "${nanopore_out}" \
      --gsa true \
      --pooled_gsa true \
      --anonymization false \
      --max_strains_per_otu 1 \
      -work-dir "${workdir}" \
      2>&1 | tee "${logfile}"); then
    t1=$(date +%s)
    log "  ✓ ${site^^} done in $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"
    fq="${nanopore_out}/sample_0/reads/fastq/sample_0.fq.gz"
    if [[ -f "$fq" ]]; then
      sz=$(stat -f%z "$fq" 2>/dev/null || stat -c%s "$fq")
      log "  Output: $fq ($(( sz/1024/1024 )) MB)"
    else
      log "  [WARN] sample_0.fq.gz not found — check $logfile"
    fi
  else
    t1=$(date +%s)
    log "  [ERROR] Nextflow failed for $site — see $logfile"
    FAILED+=("$site")
  fi
  log ""
done

log "=== LR CAMISIM Complete ==="
if [[ ${#FAILED[@]} -eq 0 ]]; then
  log "All sites done: ${SITES[*]}"
  log ""
  log "LR FASTQ outputs (use these as input to stamina-biome LR pipeline):"
  for site in "${SITES[@]}"; do
    fq="${OUTPUT_BASE}/mock_metagenome_${site}/nanopore/sample_0/reads/fastq/sample_0.fq.gz"
    [[ -f "$fq" ]] && log "  ✓ ${site}: $fq" || log "  ✗ ${site}: $fq (missing)"
  done
  exit 0
else
  log "[WARN] Failed sites: ${FAILED[*]}"
  exit 1
fi
