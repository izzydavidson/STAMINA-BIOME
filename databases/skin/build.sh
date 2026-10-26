#!/usr/bin/env bash
# databases/skin/build.sh
# Reproduce the stamina-biome-skin Kraken2 + Bracken database from scratch.
#
# Usage:
#   bash build.sh --db /path/to/output/stamina-biome-skin \
#                 --genomes /path/to/camisim_genomes/skin/fasta \
#                 [--threads 8]

set -euo pipefail

DB_PATH=""
GENOME_DIR=""
THREADS=4
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
READLENS=(500 750 1000 1200 1500 2000)
KMER=35

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)       DB_PATH="$2";     shift 2 ;;
    --genomes)  GENOME_DIR="$2";  shift 2 ;;
    --threads)  THREADS="$2";     shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$DB_PATH" ]]    && { echo "Error: --db required";      exit 1; }
[[ -z "$GENOME_DIR" ]] && { echo "Error: --genomes required"; exit 1; }
[[ -d "$GENOME_DIR" ]] || { echo "Error: genome dir not found: $GENOME_DIR"; exit 1; }

mkdir -p "$DB_PATH"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log "=== STAMINA-BIOME skin DB build ==="

log "--- Step 1/5: Download NCBI taxonomy ---"
docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --download-taxonomy --db /db

log "--- Step 2/5: Download RefSeq bacteria library ---"
docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --download-library bacteria --db /db --threads "$THREADS"

log "--- Step 3/5: Add CAMISIM simulation genomes ---"

declare -A CAMISIM_GENOMES=(
  ["GCF_006094375.1_ASM609437v1_genomic.fna"]=1282
  ["GCF_000013425.1_ASM1342v1_genomic.fna"]=1280
  ["GCF_900478045.1_47555_C02_genomic.fna"]=38301
  ["GCF_029542785.1_ASM2954278v1_genomic.fna"]=55193
  ["GCF_000181695.2_ASM18169v2_genomic.fna"]=76773
  ["GCF_900475555.1_44257_B01_genomic.fna"]=1270
  ["GCF_006094395.1_ASM609439v1_genomic.fna"]=1283
  ["GCF_001941425.1_ASM194142v1_genomic.fna"]=1697
  ["GCF_000092445.1_ASM9244v1_genomic.fna"]=1743460
)
# Note: GCF_000092445.1 is Cutibacterium acnes (taxid 1743460).
# The CAMISIM profile mislabelled this as Allopiophila luteata — the taxid
# is corrected here to ensure Kraken2 reports C. acnes correctly.

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
# 3 additional S. epidermidis assemblies for improved recall
ADDITIONAL_ACCS=("GCF_006742205.1" "GCF_019329745.1" "GCF_019329665.1")
ADDITIONAL_TAXID=1282
NCBI_FTP="https://ftp.ncbi.nlm.nih.gov/genomes/all"

for acc in "${ADDITIONAL_ACCS[@]}"; do
  log "  Fetching $acc (taxid=$ADDITIONAL_TAXID)"
  parts="${acc#*_}"; parts="${parts%%.*}"
  ftp_sub="${acc%%_*}/${parts:0:3}/${parts:3:3}/${parts:6:3}"
  folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oP "href=\"(${acc}[^\"]+)/\"" | head -1 | grep -oP "(?<=href=\")[^\"]+(?=/\")" || true)
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
for f in hash.k2d opts.k2d taxo.k2d seqid2taxid.map; do rm -f "${DB_PATH}/${f}"; done
docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --build --db /db --threads "$THREADS"
[[ -f "${DB_PATH}/hash.k2d" ]] || { log "[FATAL] hash.k2d not created"; exit 1; }
log "  Kraken2 index: $(du -sh "${DB_PATH}/hash.k2d" | cut -f1)"

log "--- Step 5/5: bracken-build ---"
for readlen in "${READLENS[@]}"; do
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    sh -c "bracken-build -d /db -t $THREADS -l $readlen -k $KMER"
  kd="${DB_PATH}/database${readlen}mers.kmer_distrib"
  [[ -f "$kd" ]] \
    && log "  ✓ ${readlen}bp kmer_distrib ($(du -sh "$kd" | cut -f1))" \
    || log "  [WARN] kmer_distrib not found for ${readlen}bp"
done

log "=== Build complete ===" && du -sh "${DB_PATH}"
