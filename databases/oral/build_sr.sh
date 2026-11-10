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
#
#   --keep-seqid-map  (full rebuild only) Do NOT delete seqid2taxid.map before kraken2-build --build.
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
    folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oE "href=\"${acc}[^\"]+/\"" | head -1 | sed -E 's/^href="//; s/\/"$//' || true)
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
fi

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
  docker run --rm -v "${DB_PATH}:/db:rw" "$DOCKER_IMAGE" \
    sh -c "bracken-build -d /db -t $THREADS -l $readlen -k $KMER"
  if [[ -f "$kd" ]]; then
    log "  ✓ database${readlen}mers.kmer_distrib ($(du -sh "$kd" | cut -f1))"
  else
    log "[FATAL] $(basename "$kd") was not created by bracken-build"; exit 1
  fi
done

log "=== SR build complete ===" && du -sh "${DB_PATH}"
