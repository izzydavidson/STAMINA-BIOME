#!/usr/bin/env bash
# databases/vaginal/build_sr.sh
# Build the stamina-biome-vaginal Kraken2 + Bracken database for SHORT READ (Illumina).
#
# The Kraken2 index is technology-independent — identical to the long-read build.
# Only Bracken kmer distributions change: 75/100/150/250 bp instead of 500-2000 bp.
#
# Two usage patterns:
#   (a) Full rebuild from scratch — same as build.sh but with SR Bracken lengths:
#       bash build_sr.sh --db /path/to/stamina-biome-vaginal-sr --genomes /path/to/vaginal/fasta
#
#   (b) Add SR Bracken to an existing LR database (faster — skips Kraken2 rebuild):
#       bash build_sr.sh --db /path/to/existing/stamina-biome-vaginal --bracken-only
#
#   --keep-seqid-map  (full rebuild only) Do NOT delete seqid2taxid.map before kraken2-build --build.
#                     By default it is deleted, and kraken2-build regenerates it
#                     from library/*/prelim_map.txt — which RE-ADDS any sequences
#                     deliberately removed from a curated map (e.g. contaminant
#                     exclusions). With this flag the existing map is used as-is,
#                     so library sequences missing from it are NOT indexed (the
#                     count is printed after the build).
#   To add genomes to an existing DB incrementally, use databases/rebuild_site_db.sh.
#
# Prerequisites:
#   - Docker with stamina-biome-tools-lr:dev image (same image; Bracken is read-length agnostic)
#   - The 17 CAMISIM simulation FASTA files (see genome_list.tsv)

set -euo pipefail

DB_PATH=""
GENOME_DIR=""
THREADS=4
KEEP_SEQID_MAP=false
BRACKEN_ONLY=false
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
READLENS=(75 100 150 250)
KMER=35

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)           DB_PATH="$2";     shift 2 ;;
    --genomes)      GENOME_DIR="$2";  shift 2 ;;
    --threads)      THREADS="$2";     shift 2 ;;
    --keep-seqid-map) KEEP_SEQID_MAP=true; shift 1 ;;
    --bracken-only) BRACKEN_ONLY=true; shift 1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$DB_PATH" ]] && { echo "Error: --db required"; exit 1; }
mkdir -p "$DB_PATH"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== STAMINA-BIOME vaginal SR build ==="
log "DB:           $DB_PATH"
log "Bracken only: $BRACKEN_ONLY"
log "Read lengths: ${READLENS[*]} bp"
log "Docker image: $DOCKER_IMAGE"

if [[ "$BRACKEN_ONLY" == "false" ]]; then
  [[ -z "$GENOME_DIR" ]] && { echo "Error: --genomes required for full build"; exit 1; }
  [[ -d "$GENOME_DIR" ]] || { echo "Error: genome dir not found: $GENOME_DIR"; exit 1; }

  # ── Step 1: Download NCBI taxonomy ─────────────────────────────────────────
  log "--- Step 1/4: Download NCBI taxonomy ---"
  docker run --rm \
    -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-taxonomy --db /db

  # ── Step 2: RefSeq backbone ─────────────────────────────────────────────────
  log "--- Step 2/4: Download RefSeq bacteria library ---"
  docker run --rm \
    -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-library bacteria --db /db --threads "$THREADS"

  # ── Step 3: Add CAMISIM simulation genomes ───────────────────────────────────
  log "--- Step 3/4: Add CAMISIM simulation genomes ---"

  declare -A TAXID_MAP=(
    ["L_crispatus_CTV05.fa"]=47770
    ["L_crispatus_JV_V01.fa"]=47770
    ["L_crispatus_CO3.fa"]=47770
    ["L_iners_KY.fa"]=147802
    ["L_iners_C0094A1.fa"]=147802
    ["L_jensenii_208-300.fa"]=109790
    ["L_gasseri_ATCC33323.fa"]=1596
    ["L_vaginalis_DSM5837.fa"]=1633
    ["Gardnerella_vaginalis_HMP9231.fa"]=2702
    ["Gardnerella_leopoldii.fa"]=2792978
    ["Gardnerella_piotii.fa"]=2792977
    ["Fannyhessea_vaginae.fa"]=82135
    ["Prevotella_bivia.fa"]=28125
    ["Mobiluncus_mulieris.fa"]=2052
    ["Streptococcus_agalactiae.fa"]=1311
    ["Ureaplasma_urealyticum.fa"]=2130
    ["Anaerococcus_prevotii.fa"]=33034
  )

  PREP_DIR=$(mktemp -d)
  trap "rm -rf $PREP_DIR" EXIT

  for fname in "${!TAXID_MAP[@]}"; do
    src="${GENOME_DIR}/${fname}"
    if [[ ! -f "$src" ]]; then
      log "  [WARN] Not found, skipping: $src"
      continue
    fi
    taxid="${TAXID_MAP[$fname]}"
    out="${PREP_DIR}/${fname}"
    python3 - "$src" "$out" "$taxid" <<'PYEOF'
import sys
src, dst, taxid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fin, open(dst, "w") as fout:
    for line in fin:
        if line.startswith(">"):
            fout.write(f">kraken:taxid|{taxid}|{line[1:].split()[0].strip()}\n")
        else:
            fout.write(line)
PYEOF
    docker run --rm \
      -v "${DB_PATH}:/db:rw" -v "${PREP_DIR}:/genomes:ro" "$DOCKER_IMAGE" \
      kraken2-build --add-to-library "/genomes/${fname}" --db /db
    log "  Added: $fname (taxid=$taxid)"
  done

  # ── Step 4a: Build Kraken2 index ─────────────────────────────────────────────
  log "--- Step 4/4: kraken2-build --build ---"
  # kraken2-build --build skips every step whose output already exists, and
  # bracken-build silently reuses an existing database.kraken (so every
  # kmer_distrib would be computed from the OLD index). Remove them all.
  STALE_FILES="hash.k2d opts.k2d taxo.k2d database.kraken"
  if [[ "$KEEP_SEQID_MAP" == "true" ]]; then
    [[ -s "${DB_PATH}/seqid2taxid.map" ]] || { log "[FATAL] --keep-seqid-map: ${DB_PATH}/seqid2taxid.map does not exist"; exit 1; }
    log "  Keeping existing seqid2taxid.map (--keep-seqid-map)"
  else
    # Regenerated from library/*/prelim_map.txt — re-adds curated exclusions.
    STALE_FILES="$STALE_FILES seqid2taxid.map"
  fi
  for f in $STALE_FILES; do rm -f "${DB_PATH}/${f}"; done
  rm -f "${DB_PATH}"/database*mers.kraken "${DB_PATH}"/database*mers.kmer_distrib
  docker run --rm \
    -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --build --db /db --threads "$THREADS"
  [[ -f "${DB_PATH}/hash.k2d" ]] || { log "[FATAL] hash.k2d not created"; exit 1; }
  if [[ "$KEEP_SEQID_MAP" == "true" ]]; then
    unmapped=$(find "${DB_PATH}/library" -maxdepth 2 -name prelim_map.txt -exec cat {} + \
      | awk -F'\t' 'NR==FNR {m[$1]=1; next} !($2 in m) {c++} END {print c+0}' "${DB_PATH}/seqid2taxid.map" -)
    if [[ "$unmapped" != "0" ]]; then
      log "  [WARN] ${unmapped} library sequence(s) are not in the kept seqid2taxid.map and were NOT indexed"
      log "         (expected only for curated exclusions; use databases/rebuild_site_db.sh to add genomes)"
    fi
  fi
  log "  Kraken2 index: $(du -sh "${DB_PATH}/hash.k2d" | cut -f1)"
fi

# ── Bracken kmer distributions (SR read lengths) ─────────────────────────────
log "--- bracken-build (SR: ${READLENS[*]} bp) ---"
# bracken-build silently reuses database.kraken. If the Kraken2 index was rebuilt
# after it was made (e.g. --bracken-only on a rebuilt DB), it is stale, and so is
# every kmer_distrib derived from it.
if [[ -f "${DB_PATH}/database.kraken" && ! "${DB_PATH}/database.kraken" -nt "${DB_PATH}/hash.k2d" ]]; then
  log "  [STALE] database.kraken predates hash.k2d — removing it"
  rm -f "${DB_PATH}/database.kraken"
fi
for kd in "${DB_PATH}"/database*mers.kmer_distrib; do
  [[ -f "$kd" ]] || continue
  case " ${READLENS[*]} " in *" $(basename "$kd" | sed -E 's/^database([0-9]+)mers.*/\1/') "*) continue ;; esac
  if [[ ! "$kd" -nt "${DB_PATH}/hash.k2d" ]]; then
    log "  [WARN] $(basename "$kd") predates hash.k2d — STALE; rebuild it with build.sh or rebuild_site_db.sh"
  fi
done
for readlen in "${READLENS[@]}"; do
  kd="${DB_PATH}/database${readlen}mers.kmer_distrib"
  if [[ -f "$kd" && "$kd" -nt "${DB_PATH}/hash.k2d" && -f "${DB_PATH}/database.kraken" ]]; then
    log "  [SKIP] ${readlen}bp kmer_distrib already exists and is newer than hash.k2d"
    continue
  fi
  rm -f "$kd" "${DB_PATH}/database${readlen}mers.kraken"
  log "  Building: ${readlen} bp"
  docker run --rm \
    -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    sh -c "bracken-build -d /db -t $THREADS -l $readlen -k $KMER"
  if [[ -f "$kd" ]]; then
    log "  ✓ database${readlen}mers.kmer_distrib ($(du -sh "$kd" | cut -f1))"
  else
    log "[FATAL] $(basename "$kd") was not created by bracken-build"; exit 1
  fi
done

log "=== SR build complete ==="
du -sh "${DB_PATH}"
