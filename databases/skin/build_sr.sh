#!/usr/bin/env bash
# databases/skin/build_sr.sh
# Build the stamina-biome-skin Kraken2 + Bracken database for SHORT READ (Illumina).
#
# Two usage patterns:
#   (a) Full rebuild from scratch:
#       bash build_sr.sh --db /path/to/stamina-biome-skin-sr --genomes /path/to/skin/fasta
#
#   (b) Add SR Bracken to an existing LR database (faster):
#       bash build_sr.sh --db /path/to/existing/stamina-biome-skin --bracken-only

set -euo pipefail

DB_PATH=""
GENOME_DIR=""
THREADS=4
BRACKEN_ONLY=false
DOCKER_IMAGE="stamina-biome-tools-lr:dev"
READLENS=(75 100 150 250)
KMER=35

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)           DB_PATH="$2";     shift 2 ;;
    --genomes)      GENOME_DIR="$2";  shift 2 ;;
    --threads)      THREADS="$2";     shift 2 ;;
    --bracken-only) BRACKEN_ONLY=true; shift 1 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$DB_PATH" ]] && { echo "Error: --db required"; exit 1; }
mkdir -p "$DB_PATH"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== STAMINA-BIOME skin SR build ==="
log "DB:           $DB_PATH"
log "Bracken only: $BRACKEN_ONLY"
log "Read lengths: ${READLENS[*]} bp"

if [[ "$BRACKEN_ONLY" == "false" ]]; then
  [[ -z "$GENOME_DIR" ]] && { echo "Error: --genomes required for full build"; exit 1; }
  [[ -d "$GENOME_DIR" ]] || { echo "Error: genome dir not found: $GENOME_DIR"; exit 1; }

  log "--- Step 1/4: Download NCBI taxonomy ---"
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-taxonomy --db /db

  log "--- Step 2/4: Download RefSeq bacteria + fungi library ---"
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-library bacteria --db /db --threads "$THREADS"
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-library fungi --db /db --threads "$THREADS"

  log "--- Step 3/4: Add CAMISIM simulation genomes ---"

  # Taxids corrected per skin/genome_list.tsv (2026-07-09 verified)
  declare -A CAMISIM_GENOMES=(
    ["GCF_006094375.1_ASM609437v1_genomic.fna"]=1282    # S. epidermidis
    ["GCF_000013425.1_ASM1342v1_genomic.fna"]=1280      # S. aureus
    ["GCF_900478045.1_47555_C02_genomic.fna"]=38304     # C. tuberculostearicum (corrected; was 38301)
    ["GCF_029542785.1_ASM2954278v1_genomic.fna"]=55193  # M. globosa
    ["GCF_000181695.2_ASM18169v2_genomic.fna"]=76773    # M. restricta
    ["GCF_900475555.1_44257_B01_genomic.fna"]=1270      # M. luteus
    ["GCF_006094395.1_ASM609439v1_genomic.fna"]=1283    # S. haemolyticus
    ["GCF_001941425.1_ASM194142v1_genomic.fna"]=1697    # B. linens
    ["GCF_000092445.1_ASM9244v1_genomic.fna"]=1743460   # C. acnes
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

  # Additional S. epidermidis assemblies
  log "  Adding additional S. epidermidis strains (taxid=1282)..."
  NCBI_FTP="https://ftp.ncbi.nlm.nih.gov/genomes/all"
  for acc in GCF_006742205.1 GCF_019329745.1 GCF_019329665.1; do
    parts="${acc#*_}"; parts="${parts%%.*}"
    ftp_sub="${acc%%_*}/${parts:0:3}/${parts:3:3}/${parts:6:3}"
    folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oP "href=\"(${acc}[^\"]+)/\"" | head -1 | grep -oP "(?<=href=\")[^\"]+(?=/\")" || true)
    [[ -z "$folder" ]] && { log "  [WARN] FTP path not found for $acc — skipping"; continue; }
    fna_url="${NCBI_FTP}/${ftp_sub}/${folder}/${folder}_genomic.fna.gz"
    tmp_gz="${PREP_DIR}/${acc}.fna.gz"; tmp_fna="${PREP_DIR}/${acc}.fna"
    curl -sL "$fna_url" -o "$tmp_gz"
    python3 - "$tmp_gz" "$tmp_fna" 1282 <<'PYEOF'
import sys, gzip
gz, out, taxid = sys.argv[1], sys.argv[2], sys.argv[3]
with gzip.open(gz, "rt") as fin, open(out, "w") as fout:
    for line in fin:
        if line.startswith(">"):
            fout.write(f">kraken:taxid|{taxid}|{line[1:].split()[0].strip()}\n")
        else:
            fout.write(line)
PYEOF
    docker run --rm -v "${DB_PATH}:/db:rw" -v "${PREP_DIR}:/genomes:ro" "$DOCKER_IMAGE" \
      kraken2-build --add-to-library "/genomes/${acc}.fna" --db /db
    log "  Added: $acc (taxid=1282)"
  done

  log "--- Step 4/4: kraken2-build --build ---"
  for f in hash.k2d opts.k2d taxo.k2d seqid2taxid.map; do rm -f "${DB_PATH}/${f}"; done
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --build --db /db --threads "$THREADS"
  [[ -f "${DB_PATH}/hash.k2d" ]] || { log "[FATAL] hash.k2d not created"; exit 1; }
  log "  Kraken2 index: $(du -sh "${DB_PATH}/hash.k2d" | cut -f1)"
fi

log "--- bracken-build (SR: ${READLENS[*]} bp) ---"
for readlen in "${READLENS[@]}"; do
  kd="${DB_PATH}/database${readlen}mers.kmer_distrib"
  if [[ -f "$kd" ]]; then
    log "  [SKIP] ${readlen}bp kmer_distrib already exists"
    continue
  fi
  log "  Building: ${readlen} bp"
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    sh -c "bracken-build -d /db -t $THREADS -l $readlen -k $KMER"
  [[ -f "$kd" ]] \
    && log "  ✓ database${readlen}mers.kmer_distrib ($(du -sh "$kd" | cut -f1))" \
    || log "  [WARN] kmer_distrib not found for ${readlen}bp"
done

log "=== SR build complete ===" && du -sh "${DB_PATH}"
