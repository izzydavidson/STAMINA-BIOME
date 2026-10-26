#!/usr/bin/env bash
# databases/skin/rebuild_mypassport.sh
# Rebuild the stamina-biome-skin Kraken2 + Bracken DB in place on MyPassport.
# Run AFTER expand_skin_db.py has added new genomes to library/added/.
#
# Usage:
#   bash databases/skin/rebuild_mypassport.sh \
#       --db /Volumes/MyPassport/custom_db/skin

set -euo pipefail

DB_PATH=""
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
THREADS=8
READLENS=(500 750 1000 1200 1500 2000)
KMER=35

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)      DB_PATH="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$DB_PATH" ]] && { echo "Error: --db required"; exit 1; }
[[ -d "$DB_PATH" ]] || { echo "Error: DB path not found: $DB_PATH"; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== STAMINA-BIOME skin DB rebuild (MyPassport) ==="
log "DB:      $DB_PATH"
log "Threads: $THREADS"
log "Image:   $DOCKER_IMAGE"
log "Library files: $(ls "$DB_PATH/library/added/" | wc -l | tr -d ' ')"

# Step 1: Delete stale index files (critical — avoids taxid=0 silent failures)
log "--- Cleaning stale index files ---"
for f in hash.k2d opts.k2d taxo.k2d seqid2taxid.map database.kraken; do
    [[ -f "$DB_PATH/$f" ]] && rm -f "$DB_PATH/$f" && log "  Deleted: $f"
done
# Remove old kmer_distrib files so they get fully regenerated
find "$DB_PATH" -maxdepth 1 -name "database*mers.kmer_distrib" -delete
find "$DB_PATH" -maxdepth 1 -name "database*mers.kraken" -delete
log "  Stale files cleared"

# Step 2: Add all genomes in library/added/ to the Kraken2 library index
# (kraken2-build --build will process library/added/ automatically)

# Step 3: Build Kraken2 index
log "--- kraken2-build --build ---"
t0=$(date +%s)
docker run --rm \
  -v "${DB_PATH}:/db:rw" \
  "$DOCKER_IMAGE" \
  kraken2-build --build --db /db --threads "$THREADS"
t1=$(date +%s)
log "  kraken2-build done: $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"

[[ -f "$DB_PATH/hash.k2d" ]] || { log "[FATAL] hash.k2d not created"; exit 1; }
log "  hash.k2d: $(du -sh "$DB_PATH/hash.k2d" | cut -f1)"

# Count unique taxids in new DB
NTAXA=$(awk '{print $2}' "$DB_PATH/seqid2taxid.map" | sort -u | wc -l | tr -d ' ')
log "  Unique taxids in rebuilt DB: $NTAXA"

# Step 4: Build Bracken kmer distributions for all read lengths
KMER2READ_BIN="${TMPDIR:-/tmp}/kmer2read_distr"
if [[ ! -f "$KMER2READ_BIN" ]]; then
  log "  Compiling kmer2read_distr from source..."
  docker run --rm \
    -v "${TMPDIR:-/tmp}:/hosttmp:rw" \
    "$DOCKER_IMAGE" \
    sh -c "apt-get update -qq 2>/dev/null && apt-get install -y build-essential -qq 2>/dev/null && cd /opt/bracken/src && make -s 2>/dev/null && cp kmer2read_distr /hosttmp/kmer2read_distr"
  [[ -f "$KMER2READ_BIN" ]] || { log "[FATAL] kmer2read_distr compilation failed"; exit 1; }
  log "  kmer2read_distr compiled OK"
fi

log "--- bracken-build (${#READLENS[@]} read lengths) ---"
for readlen in "${READLENS[@]}"; do
  log "  Building ${readlen}bp kmer_distrib..."
  t0=$(date +%s)
  docker run --rm \
    -v "${DB_PATH}:/db:rw" \
    -v "${KMER2READ_BIN}:/opt/bracken/src/kmer2read_distr:ro" \
    "$DOCKER_IMAGE" \
    /opt/bracken/bracken-build -d /db -t "$THREADS" -l "$readlen" -k "$KMER"
  t1=$(date +%s)
  kd="$DB_PATH/database${readlen}mers.kmer_distrib"
  if [[ -f "$kd" ]]; then
    log "  ✓ database${readlen}mers.kmer_distrib ($(du -sh "$kd" | cut -f1)) — $(( (t1-t0)/60 ))m $(( (t1-t0)%60 ))s"
  else
    log "  [WARN] kmer_distrib not found for ${readlen}bp"
  fi
done

log "=== Rebuild complete ==="
log "Final DB size: $(du -sh "$DB_PATH" | cut -f1)"
log "Unique taxids: $NTAXA"
