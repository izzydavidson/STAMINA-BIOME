#!/usr/bin/env bash
# rebuild_custom_dbs.sh
# Rebuild Kraken2 + Bracken indexes for gut/oral/skin custom databases
# after adding CAMISIM simulation genomes.
#
# Runs sequentially (not parallel) to avoid USB I/O contention.
# Deletes stale index files before each rebuild to force full regeneration:
#   hash.k2d opts.k2d taxo.k2d  — kraken2-build --build skips steps whose output exists
#   database.kraken, database*mers.{kraken,kmer_distrib}
#                               — bracken-build silently REUSES an existing
#                                 database.kraken, so every kmer_distrib would be
#                                 computed from the OLD index
#   seqid2taxid.map             — unless --keep-seqid-map (see below)
#
# Usage:
#   bash rebuild_custom_dbs.sh [--db-base /path/to/custom_db] [--keep-seqid-map]
#
#   --keep-seqid-map  Do NOT delete seqid2taxid.map. By default it is deleted and
#                     kraken2-build regenerates it from library/*/prelim_map.txt,
#                     which RE-ADDS any sequences deliberately removed from a
#                     curated map (e.g. contaminant exclusions). With this flag the
#                     existing map is used as-is, so library sequences missing from
#                     it are NOT indexed (the count is logged).
#
# This is a FULL rebuild of the index from the existing library. To add genomes to
# a site DB incrementally (with backup, verification and rollback) use
# databases/rebuild_site_db.sh instead. Genomes must already be registered with
# kraken2-build --add-to-library; FASTAs merely copied into library/added/ are ignored.

set -euo pipefail

# CUSTOM_DB_BASE — override with --db-base /path/to/custom_db
CUSTOM_DB_BASE="/Volumes/MyPassport/custom_db"
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
SITES=(gut oral skin)
KEEP_SEQID_MAP=false

# Parse optional --db-base argument
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-base) CUSTOM_DB_BASE="$2"; shift 2 ;;
    --keep-seqid-map) KEEP_SEQID_MAP=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done
BRACKEN_READLEN=1500
BRACKEN_KMER=35
THREADS=4

LOG_FILE="/tmp/rebuild_custom_dbs_$(date +%Y%m%d_%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_section() {
    local sep
    sep=$(printf '=%.0s' {1..60})
    log "$sep"
    log "  $*"
    log "$sep"
}

elapsed_since() {
    local start=$1
    local end
    end=$(date +%s)
    local secs=$(( end - start ))
    printf "%dm %02ds" $(( secs / 60 )) $(( secs % 60 ))
}

check_docker() {
    if ! docker info >/dev/null 2>&1; then
        log "[FATAL] Docker is not running or not accessible."
        exit 1
    fi
    # Verify the image is runnable (inspect can fail for BuildKit images; use run --rm instead)
    if ! docker run --rm "$DOCKER_IMAGE" true >/dev/null 2>&1; then
        log "[FATAL] Docker image not runnable: $DOCKER_IMAGE"
        exit 1
    fi
    log "Docker OK (image: $DOCKER_IMAGE)"
}

check_volume() {
    if [[ ! -d "$CUSTOM_DB_BASE" ]]; then
        log "[FATAL] Custom DB base not accessible: $CUSTOM_DB_BASE"
        log "[FATAL] Is the MyPassport USB drive mounted?"
        exit 1
    fi
    log "Volume OK: $CUSTOM_DB_BASE"
}

delete_stale_indexes() {
    local db_path="$1"
    local site="$2"

    log "  Deleting stale index files from $db_path ..."

    local files_deleted=0
    local stale="hash.k2d opts.k2d taxo.k2d database.kraken"
    if [[ "$KEEP_SEQID_MAP" == "true" ]]; then
        if [[ ! -s "$db_path/seqid2taxid.map" ]]; then
            log "  [ERROR] --keep-seqid-map given but $db_path/seqid2taxid.map does not exist"
            return 1
        fi
        log "    Keeping: seqid2taxid.map (--keep-seqid-map)"
    else
        stale="$stale seqid2taxid.map"
    fi
    # Bracken intermediates for every read length (all derive from database.kraken)
    local m
    for m in "$db_path"/database*mers.kraken "$db_path"/database*mers.kmer_distrib; do
        if [[ -f "$m" ]]; then stale="$stale $(basename "$m")"; fi
    done
    for f in $stale; do
        local fpath="$db_path/$f"
        if [[ -f "$fpath" ]]; then
            rm -f "$fpath"
            log "    Deleted: $f"
            (( files_deleted++ )) || true
        else
            log "    Not present (OK): $f"
        fi
    done
    log "  Stale index cleanup done ($files_deleted file(s) removed)"
}

build_kraken2() {
    local db_path="$1"
    local site="$2"
    local start
    start=$(date +%s)

    log "  Running kraken2-build --build ..."
    log "    DB: $db_path"
    log "    Threads: $THREADS"

    docker run --rm \
        -v "${db_path}:/refs/kraken2_db:rw" \
        "$DOCKER_IMAGE" \
        kraken2-build \
            --build \
            --db /refs/kraken2_db \
            --threads "$THREADS" \
        2>&1 | while IFS= read -r line; do
            log "    [kraken2] $line"
        done

    local exit_code=${PIPESTATUS[0]}
    if [[ $exit_code -ne 0 ]]; then
        log "  [ERROR] kraken2-build failed with exit code $exit_code"
        return $exit_code
    fi

    if [[ ! -s "$db_path/hash.k2d" ]]; then
        log "  [ERROR] kraken2-build exited 0 but hash.k2d was not created"
        return 1
    fi

    if [[ "$KEEP_SEQID_MAP" == "true" ]]; then
        local unmapped
        unmapped=$(find "$db_path/library" -maxdepth 2 -name prelim_map.txt -exec cat {} + \
            | awk -F'\t' 'NR==FNR {m[$1]=1; next} !($2 in m) {c++} END {print c+0}' "$db_path/seqid2taxid.map" -)
        if [[ "$unmapped" != "0" ]]; then
            log "  [WARN] $unmapped library sequence(s) are not in the kept seqid2taxid.map and were NOT indexed"
            log "         (expected only for curated exclusions)"
        fi
    fi

    log "  kraken2-build completed in $(elapsed_since "$start")"
}

build_bracken() {
    local db_path="$1"
    local site="$2"
    local start
    start=$(date +%s)

    log "  Running bracken-build (readlen=$BRACKEN_READLEN, kmer=$BRACKEN_KMER) ..."
    log "    DB: $db_path"
    log "    Threads: $THREADS"

    docker run --rm \
        -v "${db_path}:/refs/kraken2_db:rw" \
        "$DOCKER_IMAGE" \
        sh -c "export PATH=/usr/local/bin:\$PATH && bracken-build \
            -d /refs/kraken2_db \
            -t $THREADS \
            -l $BRACKEN_READLEN \
            -k $BRACKEN_KMER" \
        2>&1 | while IFS= read -r line; do
            log "    [bracken] $line"
        done

    local exit_code=${PIPESTATUS[0]}
    if [[ $exit_code -ne 0 ]]; then
        log "  [ERROR] bracken-build failed with exit code $exit_code"
        return $exit_code
    fi

    # All Bracken files were deleted before the build, so existence == fresh.
    local f
    for f in database.kraken "database${BRACKEN_READLEN}mers.kmer_distrib"; do
        if [[ ! -s "$db_path/$f" ]]; then
            log "  [ERROR] bracken-build exited 0 but $f was not created"
            return 1
        fi
    done
    log "  NOTE: all other Bracken read lengths were deleted as stale — rebuild any you need"
    log "        (e.g. databases/<site>/build_sr.sh --bracken-only for 75/100/150/250 bp)."

    log "  bracken-build completed in $(elapsed_since "$start")"
}

process_site() {
    local site="$1"
    local db_path="${CUSTOM_DB_BASE}/${site}"
    local site_start
    site_start=$(date +%s)

    local site_uc
    site_uc=$(echo "$site" | tr '[:lower:]' '[:upper:]')
    log_section "Site: ${site_uc}"
    log "  DB path: $db_path"

    if [[ ! -d "$db_path" ]]; then
        log "  [ERROR] DB directory not found: $db_path — skipping"
        return 1
    fi

    # Step 1: Delete stale indexes
    if ! delete_stale_indexes "$db_path" "$site"; then
        return 1
    fi

    # Step 2: Rebuild Kraken2
    local k2_start
    k2_start=$(date +%s)
    log ""
    log "  --- Step 1/2: kraken2-build ---"
    if ! build_kraken2 "$db_path" "$site"; then
        log "  [FATAL] kraken2-build failed for $site — stopping pipeline."
        return 1
    fi

    # Step 3: Build Bracken
    local br_start
    br_start=$(date +%s)
    log ""
    log "  --- Step 2/2: bracken-build ---"
    if ! build_bracken "$db_path" "$site"; then
        log "  [FATAL] bracken-build failed for $site — stopping pipeline."
        return 1
    fi

    log ""
    log "  Site ${site_uc} COMPLETE — total time: $(elapsed_since "$site_start")"
}

# ---- Main ----

echo ""
log_section "STAMINA-BIOME: Rebuild Custom Kraken2+Bracken DBs"
log "Log file: $LOG_FILE"
log "Sites: ${SITES[*]}"
log "Docker image: $DOCKER_IMAGE"
log "Bracken readlen: $BRACKEN_READLEN"
log "Keep seqid2taxid.map: $KEEP_SEQID_MAP"
log ""

check_docker
check_volume

TOTAL_START=$(date +%s)
FAILED_SITES=()

for site in "${SITES[@]}"; do
    if ! process_site "$site"; then
        FAILED_SITES+=("$site")
        log "[WARN] Site $site failed — continuing with remaining sites."
    fi
    log ""
done

log_section "REBUILD COMPLETE"
log "Total time: $(elapsed_since "$TOTAL_START")"

if [[ ${#FAILED_SITES[@]} -eq 0 ]]; then
    log "All sites rebuilt successfully: ${SITES[*]}"
    log "Full log: $LOG_FILE"
    exit 0
else
    log "[WARN] Failed sites: ${FAILED_SITES[*]}"
    log "Check log for details: $LOG_FILE"
    exit 1
fi
