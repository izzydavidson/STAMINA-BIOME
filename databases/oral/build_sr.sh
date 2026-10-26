#!/usr/bin/env bash
# databases/oral/build_sr.sh
# Build the stamina-biome-oral Kraken2 + Bracken database for SHORT READ (Illumina).
#
# Two usage patterns:
#   (a) Full rebuild from scratch:
#       bash build_sr.sh --db /path/to/stamina-biome-oral-sr --genomes /path/to/oral/fasta
#
#   (b) Add SR Bracken to an existing LR database (faster):
#       bash build_sr.sh --db /path/to/existing/stamina-biome-oral --bracken-only

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

log "=== STAMINA-BIOME oral SR build ==="
log "DB:           $DB_PATH"
log "Bracken only: $BRACKEN_ONLY"
log "Read lengths: ${READLENS[*]} bp"

if [[ "$BRACKEN_ONLY" == "false" ]]; then
  [[ -z "$GENOME_DIR" ]] && { echo "Error: --genomes required for full build"; exit 1; }
  [[ -d "$GENOME_DIR" ]] || { echo "Error: genome dir not found: $GENOME_DIR"; exit 1; }

  log "--- Step 1/4: Download NCBI taxonomy ---"
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-taxonomy --db /db

  log "--- Step 2/4: Download RefSeq bacteria library ---"
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    kraken2-build --download-library bacteria --db /db --threads "$THREADS"

  log "--- Step 3/4: Add CAMISIM simulation genomes ---"

  # Taxids corrected per oral/genome_list.tsv (2026-07-09 verified)
  declare -A CAMISIM_GENOMES=(
    ["GCF_900637025.1_46338_H01_genomic.fna"]=28037   # S. mitis (corrected; was 1303=S.oralis)
    ["GCF_000164675.2_ASM16467v2_genomic.fna"]=1304   # S. salivarius (corrected; was 1318=S.parasanguinis)
    ["GCF_900186885.1_48903_D01_genomic.fna"]=29466   # V. parvula
    ["GCF_900625065.1_PRJEB29221_genomic.fna"]=28132  # P. melaninogenica (corrected; was 838=genus)
    ["GCF_003019295.1_ASM301929v1_genomic.fna"]=851   # F. nucleatum
    ["GCF_900636915.1_45532_F02_genomic.fna"]=729     # H. parainfluenzae (corrected; was 732=A.aphrophilus)
    ["GCF_000212375.1_ASM21237v1_genomic.fna"]=837    # P. gingivalis (corrected; was 836=genus)
    ["GCA_000011025.1_ASM1102v1_genomic.fna"]=43675   # R. mucilaginosa
    ["GCF_900475315.1_43721_G02_genomic.fna"]=28449   # N. subflava (corrected; was 483=N.cinerea)
    ["GCF_004362855.1_ASM436285v1_genomic.fna"]=28112 # T. forsythia (corrected; was 224471=wrong)
    ["GCF_016127855.1_ASM1612785v1_genomic.fna"]=1655 # A. naeslundii (corrected; was 1760=class)
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

  # Additional S. oralis strains for improved recall
  log "  Adding additional S. oralis strains (taxid=1303)..."
  NCBI_FTP="https://ftp.ncbi.nlm.nih.gov/genomes/all"
  for acc in GCF_016127555.1 GCF_018985485.2 GCF_023611505.1; do
    parts="${acc#*_}"; parts="${parts%%.*}"
    ftp_sub="${acc%%_*}/${parts:0:3}/${parts:3:3}/${parts:6:3}"
    folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oP "href=\"(${acc}[^\"]+)/\"" | head -1 | grep -oP "(?<=href=\")[^\"]+(?=/\")" || true)
    [[ -z "$folder" ]] && { log "  [WARN] FTP path not found for $acc — skipping"; continue; }
    fna_url="${NCBI_FTP}/${ftp_sub}/${folder}/${folder}_genomic.fna.gz"
    tmp_gz="${PREP_DIR}/${acc}.fna.gz"; tmp_fna="${PREP_DIR}/${acc}.fna"
    curl -sL "$fna_url" -o "$tmp_gz"
    python3 - "$tmp_gz" "$tmp_fna" 1303 <<'PYEOF'
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
    log "  Added: $acc (taxid=1303)"
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
