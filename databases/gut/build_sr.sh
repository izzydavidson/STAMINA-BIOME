#!/usr/bin/env bash
# databases/gut/build_sr.sh
# Build the stamina-biome-gut Kraken2 + Bracken database for SHORT READ (Illumina).
#
# Two usage patterns:
#   (a) Full rebuild from scratch:
#       bash build_sr.sh --db /path/to/stamina-biome-gut-sr --genomes /path/to/gut/fasta
#
#   (b) Add SR Bracken to an existing LR database (faster):
#       bash build_sr.sh --db /path/to/existing/stamina-biome-gut --bracken-only
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

log "=== STAMINA-BIOME gut SR build ==="
log "DB:           $DB_PATH"
log "Bracken only: $BRACKEN_ONLY"
log "Read lengths: ${READLENS[*]} bp"
log "Docker image: $DOCKER_IMAGE"

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

  # Taxids corrected per genome_list.tsv (2026-07-09 verified)
  declare -A CAMISIM_GENOMES=(
    ["GCF_014131755.1_ASM1413175v1_genomic.fna"]=818      # B. thetaiotaomicron
    ["GCF_000154385.1_ASM15438v1_genomic.fna"]=853        # F. prausnitzii
    ["GCF_012932365.1_ASM1293236v1_genomic.fna"]=1678     # B. longum
    ["GCF_009731575.1_ASM973157v1_genomic.fna"]=239935    # A. muciniphila
    ["GCF_000008865.2_ASM886v2_genomic.fna"]=562          # E. coli
    ["GCF_000014425.1_ASM1442v1_genomic.fna"]=47715       # L. rhamnosus (corrected; was 1596)
    ["GCF_025147765.1_ASM2514776v1_genomic.fna"]=166486   # R. intestinalis (corrected; was 40520)
    ["GCF_016027375.1_ASM1602737v1_genomic.fna"]=1496     # C. difficile (corrected; was 1502)
    ["GCF_000025985.1_ASM2598v1_genomic.fna"]=817         # B. fragilis
    ["GCF_020735445.1_ASM2073544v1_genomic.fna"]=165179   # P. copri
    ["GCF_900537995.1_Roseburia_intestinalis_strain_L1-82_genomic.fna"]=33038  # M. gnavus (corrected; was 166486)
    ["GCF_025998455.1_ASM2599845v1_genomic.fna"]=210      # H. pylori
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

  # Additional NCBI strains for recall improvement (see genome_list.tsv)
  log "  Adding additional NCBI strains (B. thetaiotaomicron, H. pylori, L. gasseri)..."
  ADDITIONAL=(
    "GCF_022453665.1 818"  "GCF_019857385.1 818"  "GCF_019896115.1 818"
    "GCF_003050665.1 210"  "GCF_004295525.1 210"  "GCF_900478295.1 210"
    "GCF_040050875.1 1596" "GCF_002158885.1 1596" "GCF_013363915.1 1596"
    "GCF_017840575.1 1596"
  )
  NCBI_FTP="https://ftp.ncbi.nlm.nih.gov/genomes/all"
  for entry in "${ADDITIONAL[@]}"; do
    acc=$(echo "$entry" | cut -d' ' -f1)
    taxid=$(echo "$entry" | cut -d' ' -f2)
    parts="${acc#*_}"; parts="${parts%%.*}"
    ftp_sub="${acc%%_*}/${parts:0:3}/${parts:3:3}/${parts:6:3}"
    folder=$(curl -s "${NCBI_FTP}/${ftp_sub}/" | grep -oE "href=\"${acc}[^\"]+/\"" | head -1 | sed -E 's/^href="//; s/\/"$//' || true)
    [[ -z "$folder" ]] && { log "  [WARN] FTP path not found for $acc — skipping"; continue; }
    fna_url="${NCBI_FTP}/${ftp_sub}/${folder}/${folder}_genomic.fna.gz"
    tmp_gz="${PREP_DIR}/${acc}.fna.gz"; tmp_fna="${PREP_DIR}/${acc}.fna"
    curl -sL "$fna_url" -o "$tmp_gz"
    python3 - "$tmp_gz" "$tmp_fna" "$taxid" <<'PYEOF'
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
    log "  Added: $acc (taxid=$taxid)"
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
