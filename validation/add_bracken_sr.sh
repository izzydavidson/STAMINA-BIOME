#!/usr/bin/env bash
# validation/add_bracken_sr.sh
# Add short-read Bracken kmer distributions (75/100/150/250 bp) to existing
# STAMINA-BIOME databases without rebuilding the Kraken2 index.
#
# Use this when you already have the LR databases and just need SR Bracken files.
# Kraken2 databases are read-length agnostic — only Bracken kmer_distrib files
# are read-length dependent, so this is much faster than a full rebuild.
#
# Usage:
#   bash add_bracken_sr.sh --db-base /Volumes/MyPassport/custom_db [--threads 4]
#   bash add_bracken_sr.sh --db-base /Volumes/MyPassport/custom_db --sites gut,oral

set -euo pipefail

DB_BASE="/Volumes/MyPassport/custom_db"
SITES=(vaginal gut oral skin)
THREADS=4
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
READLENS=(75 100 150 250)
KMER=35
LOG="/tmp/add_bracken_sr_$(date +%Y%m%d_%H%M%S).log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/bracken_build_helpers"
# stamina-biome-tools-lr:dev / stamina-biome-tools-sr:dev ship bracken-build at /opt/bracken/bracken-build
# (not on PATH) with two dependencies never installed on PATH either: the compiled
# kmer2read_distr binary and generate_kmer_distribution.py. Without both, bracken-build's
# PATH-detection branch has an unquoted `[ -f $(command -v ...) ]` bug that silently
# "succeeds" (exit 0) while actually invoking `python -i <kraken-report>` and producing no
# output file. Mounting the pre-built helpers here onto PATH avoids both issues.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-base) DB_BASE="$2"; shift 2 ;;
    --sites)   IFS=',' read -ra SITES <<< "$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { local msg="[$(date '+%H:%M:%S')] $*"; echo "$msg"; echo "$msg" >> "$LOG"; }

if [[ ! -d "$DB_BASE" ]]; then
  log "[FATAL] DB base not accessible: $DB_BASE"
  log "        Is the drive mounted?"
  exit 1
fi

log "=== STAMINA-BIOME: Add Short-Read Bracken Distributions ==="
log "DB base:  $DB_BASE"
log "Sites:    ${SITES[*]}"
log "Lengths:  ${READLENS[*]} bp"
log "Log:      $LOG"
log ""

FAILED=()
for site in "${SITES[@]}"; do
  db="${DB_BASE}/${site}"
  log "━━━ Site: ${site^^} ━━━"

  if [[ ! -f "${db}/hash.k2d" ]]; then
    log "  [ERROR] No Kraken2 index found at ${db}/hash.k2d — run build.sh first"
    FAILED+=("$site")
    continue
  fi

  for readlen in "${READLENS[@]}"; do
    kd="${db}/database${readlen}mers.kmer_distrib"
    if [[ -f "$kd" ]]; then
      sz=$(stat -f%z "$kd" 2>/dev/null || stat -c%s "$kd" 2>/dev/null)
      log "  [SKIP] ${readlen}bp — already exists (${sz} bytes)"
      continue
    fi

    log "  Building ${readlen}bp kmer_distrib..."
    t0=$(date +%s)
    docker run --rm \
      -v "${db}:/refs/kraken2_db:rw" \
      -v "${HELPERS_DIR}/kmer2read_distr:/usr/local/bin/kmer2read_distr:ro" \
      -v "${HELPERS_DIR}/generate_kmer_distribution.py:/usr/local/bin/generate_kmer_distribution.py:ro" \
      "$DOCKER_IMAGE" \
      sh -c "/opt/bracken/bracken-build -d /refs/kraken2_db -t $THREADS -l $readlen -k $KMER" \
      2>&1 | while IFS= read -r line; do log "    [bracken] $line"; done || true
    t1=$(date +%s)

    if [[ -f "$kd" ]]; then
      sz=$(stat -f%z "$kd" 2>/dev/null || stat -c%s "$kd" 2>/dev/null)
      log "  ✓ database${readlen}mers.kmer_distrib — ${sz} bytes — $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"
    else
      log "  [WARN] kmer_distrib not found after build for ${readlen}bp"
    fi
  done

  log "  ${site^^} SR Bracken complete."
  log ""
done

log "=== add_bracken_sr complete ==="
if [[ ${#FAILED[@]} -eq 0 ]]; then
  log "All sites done: ${SITES[*]}"
  log ""
  log "SR kmer_distrib files now present:"
  for site in "${SITES[@]}"; do
    for rl in "${READLENS[@]}"; do
      kd="${DB_BASE}/${site}/database${rl}mers.kmer_distrib"
      [[ -f "$kd" ]] && log "  ✓ ${site}/${rl}bp" || log "  ✗ ${site}/${rl}bp (missing)"
    done
  done
  exit 0
else
  log "[WARN] Failed sites: ${FAILED[*]}"
  exit 1
fi
