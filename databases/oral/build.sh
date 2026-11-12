#!/usr/bin/env bash
# databases/oral/build.sh
# Reproduce the stamina-biome-oral Kraken2 + Bracken database from scratch.
#
# Usage:
#   bash build.sh --db /path/to/output/stamina-biome-oral \
#                 --genomes /path/to/camisim_genomes/oral/fasta \
#                 [--threads 8] [--keep-seqid-map]
#
#   --keep-seqid-map  Do NOT delete seqid2taxid.map before kraken2-build --build.
#                     By default it is deleted, and kraken2-build regenerates it
#                     from library/*/prelim_map.txt — which RE-ADDS any sequences
#                     deliberately removed from a curated map (e.g. contaminant
#                     exclusions). With this flag the existing map is used as-is,
#                     so library sequences missing from it are NOT indexed (the
#                     count is printed after the build).
#   To add genomes to an existing DB incrementally, use databases/rebuild_site_db.sh.

set -euo pipefail

DB_PATH=""
GENOME_DIR=""
THREADS=4
KEEP_SEQID_MAP=false
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
READLENS=(500 750 1000 1200 1500 2000)
KMER=35

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)       DB_PATH="$2";     shift 2 ;;
    --genomes)  GENOME_DIR="$2";  shift 2 ;;
    --threads)  THREADS="$2";     shift 2 ;;
    --keep-seqid-map) KEEP_SEQID_MAP=true; shift 1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$DB_PATH" ]]    && { echo "Error: --db required";      exit 1; }
[[ -z "$GENOME_DIR" ]] && { echo "Error: --genomes required"; exit 1; }
[[ -d "$GENOME_DIR" ]] || { echo "Error: genome dir not found: $GENOME_DIR"; exit 1; }

mkdir -p "$DB_PATH"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log "=== STAMINA-BIOME oral DB build ==="

log "--- Step 1/5: Download NCBI taxonomy ---"
docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --download-taxonomy --db /db

log "--- Step 2/5: Download RefSeq bacteria library ---"
docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --download-library bacteria --db /db --threads "$THREADS"

log "--- Step 3/5: Add CAMISIM simulation genomes ---"

declare -A CAMISIM_GENOMES=(
  ["GCF_900637025.1_46338_H01_genomic.fna"]=1303
  ["GCF_000164675.2_ASM16467v2_genomic.fna"]=1318
  ["GCF_900186885.1_48903_D01_genomic.fna"]=29466
  ["GCF_900625065.1_PRJEB29221_genomic.fna"]=838
  ["GCF_003019295.1_ASM301929v1_genomic.fna"]=851
  ["GCF_900636915.1_45532_F02_genomic.fna"]=732
  ["GCF_000212375.1_ASM21237v1_genomic.fna"]=836
  ["GCA_000011025.1_ASM1102v1_genomic.fna"]=43675
  ["GCF_900475315.1_43721_G02_genomic.fna"]=483
  ["GCF_004362855.1_ASM436285v1_genomic.fna"]=224471
  ["GCF_016127855.1_ASM1612785v1_genomic.fna"]=1760
)

PREP_DIR=$(mktemp -d)
trap "rm -rf $PREP_DIR" EXIT

for fname in "${!CAMISIM_GENOMES[@]}"; do
  src="${GENOME_DIR}/${fname}"
  if [[ ! -f "$src" ]]; then
    log "  [WARN] Not found, skipping: $src"
    continue
  fi
  taxid="${CAMISIM_GENOMES[$fname]}"
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

log "--- Step 3b/5: Download and add additional NCBI strains ---"
# 4 additional Streptococcus oralis assemblies (taxid 1303) for improved recall
ADDITIONAL_ACCS=("GCF_016127555.1" "GCF_018985485.2" "GCF_023611505.1")
ADDITIONAL_TAXID=1303
NCBI_FTP="https://ftp.ncbi.nlm.nih.gov/genomes/all"

for acc in "${ADDITIONAL_ACCS[@]}"; do
  log "  Fetching $acc (taxid=$ADDITIONAL_TAXID)"
  parts="${acc#*_}"; parts="${parts%%.*}"
  ftp_sub="${acc%%_*}/${parts:0:3}/${parts:3:3}/${parts:6:3}"
  folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oE "href=\"${acc}[^\"]+/\"" | head -1 | sed -E 's/^href="//; s/\/"$//' || true)
  if [[ -z "$folder" ]]; then
    log "  [WARN] Could not resolve FTP path for $acc — skipping"
    continue
  fi
  fna_url="${NCBI_FTP}/${ftp_sub}/${folder}/${folder}_genomic.fna.gz"
  tmp_gz="${PREP_DIR}/${acc}.fna.gz"
  tmp_fna="${PREP_DIR}/${acc}.fna"
  curl -sL "$fna_url" -o "$tmp_gz"
  python3 - "$tmp_gz" "$tmp_fna" "$ADDITIONAL_TAXID" <<'PYEOF'
import sys, gzip
gz, out, taxid = sys.argv[1], sys.argv[2], sys.argv[3]
with gzip.open(gz, "rt") as fin, open(out, "w") as fout:
    for line in fin:
        if line.startswith(">"):
            fout.write(f">kraken:taxid|{taxid}|{line[1:].split()[0].strip()}\n")
        else:
            fout.write(line)
PYEOF
  docker run --rm \
    -v "${DB_PATH}:/db:rw" -v "${PREP_DIR}:/genomes:ro" "$DOCKER_IMAGE" \
    kraken2-build --add-to-library "/genomes/${acc}.fna" --db /db
  log "  Added: $acc"
done

log "--- Step 4/5: kraken2-build --build ---"
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
docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
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

log "--- Step 5/5: bracken-build ---"
for readlen in "${READLENS[@]}"; do
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    sh -c "bracken-build -d /db -t $THREADS -l $readlen -k $KMER"
  kd="${DB_PATH}/database${readlen}mers.kmer_distrib"
  if [[ -f "$kd" ]]; then
    log "  ✓ ${readlen}bp kmer_distrib ($(du -sh "$kd" | cut -f1))"
  else
    log "[FATAL] $(basename "$kd") was not created by bracken-build"; exit 1
  fi
done

log "=== Build complete ===" && du -sh "${DB_PATH}"
