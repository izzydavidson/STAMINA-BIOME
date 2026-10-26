#!/usr/bin/env bash
# databases/gut/build.sh
# Reproduce the stamina-biome-gut Kraken2 + Bracken database from scratch.
#
# Prerequisites:
#   - Docker with stamina-biome-tools-lr:dev image
#   - ~20 GB free disk space at DB_PATH
#   - Internet access (NCBI FTP for taxonomy, RefSeq, and additional genomes)
#   - The gut CAMISIM FASTA files (see genome_list.tsv for accessions)
#
# Usage:
#   bash build.sh --db /path/to/output/stamina-biome-gut \
#                 --genomes /path/to/camisim_genomes/gut/fasta \
#                 [--threads 8]

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
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

log "=== STAMINA-BIOME gut DB build ==="
log "DB:      $DB_PATH"
log "Genomes: $GENOME_DIR"
log "Threads: $THREADS"

# ── Step 1: Taxonomy ─────────────────────────────────────────────────────────
log "--- Step 1/5: Download NCBI taxonomy ---"
docker run --rm \
  -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --download-taxonomy --db /db

# ── Step 2: RefSeq backbone ───────────────────────────────────────────────────
log "--- Step 2/5: Download RefSeq bacteria library ---"
docker run --rm \
  -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --download-library bacteria --db /db --threads "$THREADS"

# ── Step 3: Add CAMISIM simulation genomes ────────────────────────────────────
log "--- Step 3/5: Add CAMISIM simulation genomes ---"

# accession → (taxid, label in genome_list.tsv)
declare -A CAMISIM_GENOMES=(
  ["GCF_014131755.1_ASM1413175v1_genomic.fna"]=818
  ["GCF_000154385.1_ASM15438v1_genomic.fna"]=853
  ["GCF_012932365.1_ASM1293236v1_genomic.fna"]=1678
  ["GCF_009731575.1_ASM973157v1_genomic.fna"]=239935
  ["GCF_000008865.2_ASM886v2_genomic.fna"]=562
  ["GCF_000014425.1_ASM1442v1_genomic.fna"]=1596
  ["GCF_025147765.1_ASM2514776v1_genomic.fna"]=40520
  ["GCF_016027375.1_ASM1602737v1_genomic.fna"]=1502
  ["GCF_000025985.1_ASM2598v1_genomic.fna"]=817
  ["GCF_020735445.1_ASM2073544v1_genomic.fna"]=165179
  ["GCF_900537995.1_Roseburia_intestinalis_strain_L1-82_genomic.fna"]=166486
  ["GCF_025998455.1_ASM2599845v1_genomic.fna"]=210
)

PREP_DIR=$(mktemp -d)
trap "rm -rf $PREP_DIR" EXIT

add_genome() {
  local src="$1" taxid="$2" fname
  fname=$(basename "$src")
  local out="${PREP_DIR}/${fname}"
  python3 - "$src" "$out" "$taxid" <<'PYEOF'
import sys
src, dst, taxid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fin, open(dst, "w") as fout:
    for line in fin:
        if line.startswith(">"):
            seq_id = line[1:].split()[0].strip()
            fout.write(f">kraken:taxid|{taxid}|{seq_id}\n")
        else:
            fout.write(line)
PYEOF
  docker run --rm \
    -v "${DB_PATH}:/db:rw" \
    -v "${PREP_DIR}:/genomes:ro" \
    "$DOCKER_IMAGE" \
    kraken2-build --add-to-library "/genomes/${fname}" --db /db
  log "  Added: $fname (taxid=$taxid)"
}

for fname in "${!CAMISIM_GENOMES[@]}"; do
  src="${GENOME_DIR}/${fname}"
  if [[ ! -f "$src" ]]; then
    log "  [WARN] Not found, skipping: $src"
    continue
  fi
  add_genome "$src" "${CAMISIM_GENOMES[$fname]}"
done

# ── Step 4: Download and add additional NCBI strains ──────────────────────────
# These extra assemblies were added to improve per-species recall for
# B. thetaiotaomicron, H. pylori, and L. gasseri (see genome_list.tsv).
log "--- Step 4/5 (sub): Add additional NCBI RefSeq strains ---"

# Format: "accession taxid"
ADDITIONAL=(
  "GCF_022453665.1 818"
  "GCF_019857385.1 818"
  "GCF_019896115.1 818"
  "GCF_003050665.1 210"
  "GCF_004295525.1 210"
  "GCF_900478295.1 210"
  "GCF_040050875.1 1596"
  "GCF_002158885.1 1596"
  "GCF_013363915.1 1596"
  "GCF_017840575.1 1596"
)

python3 "$(dirname "$0")/../../validation/add_ncbi_strains.py" \
  --site gut \
  --accessions "${ADDITIONAL[@]}" \
  --prep-dir "$PREP_DIR" \
  --db-path "$DB_PATH" \
  --docker-image "$DOCKER_IMAGE" 2>/dev/null \
|| {
  # Fallback: download manually if add_ncbi_strains.py signature differs
  log "  [INFO] Running manual NCBI download for additional strains..."
  NCBI_FTP="https://ftp.ncbi.nlm.nih.gov/genomes/all"
  for entry in "${ADDITIONAL[@]}"; do
    acc=$(echo "$entry" | cut -d' ' -f1)
    taxid=$(echo "$entry" | cut -d' ' -f2)
    log "  Fetching $acc (taxid=$taxid)"
    parts="${acc#*_}"; parts="${parts%%.*}"
    ftp_sub="${acc%%_*}/${parts:0:3}/${parts:3:3}/${parts:6:3}"
    # Find versioned folder
    folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oP "href=\"(${acc}[^\"]+)/\"" | head -1 | grep -oP "(?<=href=\")[^\"]+(?=/\")")
    if [[ -z "$folder" ]]; then
      log "  [WARN] Could not resolve FTP folder for $acc — skipping"
      continue
    fi
    fna_url="${NCBI_FTP}/${ftp_sub}/${folder}/${folder}_genomic.fna.gz"
    tmp_gz="${PREP_DIR}/${acc}_genomic.fna.gz"
    tmp_fna="${PREP_DIR}/${acc}_genomic.fna"
    curl -sL "$fna_url" -o "$tmp_gz"
    python3 - "$tmp_gz" "$tmp_fna" "$taxid" <<'PYEOF'
import sys, gzip
gz, out, taxid = sys.argv[1], sys.argv[2], sys.argv[3]
with gzip.open(gz, "rt") as fin, open(out, "w") as fout:
    for line in fin:
        if line.startswith(">"):
            seq_id = line[1:].split()[0].strip()
            fout.write(f">kraken:taxid|{taxid}|{seq_id}\n")
        else:
            fout.write(line)
PYEOF
    docker run --rm \
      -v "${DB_PATH}:/db:rw" \
      -v "${PREP_DIR}:/genomes:ro" \
      "$DOCKER_IMAGE" \
      kraken2-build --add-to-library "/genomes/${acc}_genomic.fna" --db /db
    log "  Added: $acc"
  done
}

# ── Step 5: Build Kraken2 index ───────────────────────────────────────────────
log "--- Step 4/5: kraken2-build --build ---"
for f in hash.k2d opts.k2d taxo.k2d seqid2taxid.map; do rm -f "${DB_PATH}/${f}"; done

docker run --rm \
  -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
  kraken2-build --build --db /db --threads "$THREADS"

[[ -f "${DB_PATH}/hash.k2d" ]] || { log "[FATAL] hash.k2d not created"; exit 1; }
log "  Kraken2 index: $(du -sh "${DB_PATH}/hash.k2d" | cut -f1)"

# ── Step 6: Bracken kmer distributions ───────────────────────────────────────
log "--- Step 5/5: bracken-build ---"
for readlen in "${READLENS[@]}"; do
  log "  Read length: ${readlen} bp"
  docker run --rm \
    -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    sh -c "bracken-build -d /db -t $THREADS -l $readlen -k $KMER"
  kd="${DB_PATH}/database${readlen}mers.kmer_distrib"
  [[ -f "$kd" ]] \
    && log "  ✓ database${readlen}mers.kmer_distrib ($(du -sh "$kd" | cut -f1))" \
    || log "  [WARN] kmer_distrib not found for ${readlen}bp"
done

log "=== Build complete ==="
du -sh "${DB_PATH}"
