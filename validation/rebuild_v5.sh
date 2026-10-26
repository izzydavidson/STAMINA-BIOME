#!/usr/bin/env bash
# rebuild_v5.sh — Rebuild gut/oral/skin custom DBs (v5: CAMISIM + additional NCBI strains)
# Run AFTER v4c pipelines complete.
set -euo pipefail

# CUSTOM_DB_BASE — override with --db-base /path/to/custom_db
CUSTOM_DB_BASE="/Volumes/MyPassport/custom_db"
SITES=(gut oral skin)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-base) CUSTOM_DB_BASE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
READLEN=1500
KMER=35
THREADS=4
LOG="/tmp/rebuild_v5_$(date +%Y%m%d_%H%M%S).log"

log() { local msg="[$(date '+%H:%M:%S')] $*"; echo "$msg"; echo "$msg" >> "$LOG"; }

log "=== STAMINA-BIOME v5 DB Rebuild ==="
log "Log: $LOG"
log ""

for site in "${SITES[@]}"; do
  db="${CUSTOM_DB_BASE}/${site}"
  log "━━━ Site: ${site^^} ━━━"

  # 1. Delete stale index + bracken files (use find, not glob, to avoid nomatch)
  log "  Cleaning stale files..."
  find "$db" -maxdepth 1 \
    \( -name "hash.k2d" -o -name "opts.k2d" -o -name "taxo.k2d" \
       -o -name "seqid2taxid.map" -o -name "database.kraken" \
       -o -name "database*mers.kraken" -o -name "database*mers.kmer_distrib" \) \
    -print -delete 2>/dev/null || true
  log "  Cleaned."

  # 2. kraken2-build
  log "  kraken2-build (threads=$THREADS)..."
  t0=$(date +%s)
  docker run --rm \
    -v "${db}:/refs/kraken2_db:rw" \
    "$DOCKER_IMAGE" \
    kraken2-build --build --db /refs/kraken2_db --threads "$THREADS" \
    2>&1 | while IFS= read -r line; do log "    [k2] $line"; done || true
  t1=$(date +%s)
  log "  kraken2-build done: $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"
  [[ -f "$db/hash.k2d" ]] || { log "  [FATAL] hash.k2d not created — stopping"; exit 1; }

  # 3. bracken-build (compile kmer2read_distr from source first)
  log "  bracken-build (readlen=$READLEN)..."
  t0=$(date +%s)
  docker run --rm \
    -v "${db}:/refs/kraken2_db:rw" \
    "$DOCKER_IMAGE" \
    sh -c "
      set -e
      apt-get update -qq 2>&1 | tail -1
      apt-get install -y -q g++ 2>&1 | grep 'Setting up g++' || true
      cd /opt/bracken/src
      g++ -O3 -std=c++11 -fopenmp -o /opt/bracken/src/kmer2read_distr \
          kmer2read_distr.cpp ctime.cpp taxonomy.cpp kraken_processing.cpp -lgomp 2>/dev/null
      echo 'kmer2read_distr compiled'
      /opt/bracken/bracken-build -d /refs/kraken2_db -t $THREADS -l $READLEN -k $KMER
    " 2>&1 | grep -E "compiled|kmer_distrib|complete|Error|STEP [34]" | \
      while IFS= read -r line; do log "    [br] $line"; done || true
  t1=$(date +%s)
  log "  bracken-build done: $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"

  # 4. Verify
  kd="${db}/database${READLEN}mers.kmer_distrib"
  if [[ -f "$kd" ]]; then
    sz=$(stat -f%z "$kd" 2>/dev/null || stat -c%s "$kd" 2>/dev/null)
    log "  ✓ kmer_distrib: ${sz} bytes"
  else
    log "  [WARN] kmer_distrib NOT found"
  fi
  log ""
done

log "=== v5 Rebuild complete ==="
ls -lh "${CUSTOM_DB_BASE}"/*/database${READLEN}mers.kmer_distrib 2>/dev/null | \
  while IFS= read -r line; do log "  $line"; done
