#!/usr/bin/env python3
"""
expand_skin_db.py — Download representative genomes for all skin-relevant
organisms not already present in the stamina-biome-skin Kraken2 database,
rewrite FASTA headers to kraken:taxid format, and add to the library.

Usage:
    python3 expand_skin_db.py \
        --db /Volumes/MyPassport/custom_db/skin \
        [--threads 4]

After running, rebuild the database:
    bash databases/skin/rebuild_mypassport.sh
"""

import argparse
import csv
import gzip
import os
import sys
import time
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# ── Comprehensive skin microbiome species list ────────────────────────────────
# Sources: HMP skin site data, Grice & Segre (2011) Nat Rev Microbiol,
#          Byrd et al. (2018) Nat Rev Microbiol, Findley et al. (2013) Nature
#
# Format: species_taxid → "Genus species"
# Only species-level taxids (not strain-level) — Kraken2 will resolve strains
# to the species node for classification.

SKIN_TAXA = {
    # ── Staphylococcus ────────────────────────────────────────────────────────
    1280:   "Staphylococcus aureus",
    1281:   "Staphylococcus carnosus",
    1282:   "Staphylococcus epidermidis",
    1283:   "Staphylococcus haemolyticus",
    1284:   "Staphylococcus hominis",
    1285:   "Staphylococcus lugdunensis",
    1286:   "Staphylococcus saprophyticus",
    1287:   "Staphylococcus cohnii",
    1288:   "Staphylococcus xylosus",
    1289:   "Staphylococcus caprae",
    1290:   "Staphylococcus schleiferi",
    1291:   "Staphylococcus intermedius",
    1292:   "Staphylococcus lentus",
    1293:   "Staphylococcus sciuri",
    1294:   "Staphylococcus vitulinus",
    1295:   "Staphylococcus warneri",
    29376:  "Staphylococcus capitis",
    29380:  "Staphylococcus arlettae",
    29382:  "Staphylococcus cohnii",
    29385:  "Staphylococcus lentus",
    29388:  "Staphylococcus sciuri",
    45972:  "Staphylococcus pasteuri",
    246432: "Staphylococcus equorum",
    283734: "Staphylococcus pettenkoferi",
    # ── Corynebacterium ───────────────────────────────────────────────────────
    1697:   "Corynebacterium glutamicum",
    1698:   "Corynebacterium diphtheriae",
    1703:   "Corynebacterium xerosis",
    1716:   "Corynebacterium pseudodiphtheriticum",
    1718:   "Corynebacterium bovis",
    1725:   "Corynebacterium renale",
    1728:   "Corynebacterium ulcerans",
    28419:  "Corynebacterium argentoratense",
    28423:  "Corynebacterium auriscanis",
    38284:  "Corynebacterium minutissimum",
    38285:  "Corynebacterium freneyi",
    38286:  "Corynebacterium pseudogenitalium",
    38287:  "Corynebacterium durum",
    38289:  "Corynebacterium accolens",
    38290:  "Corynebacterium pseudodiphtheriticum",
    38291:  "Corynebacterium glucuronolyticum",
    38299:  "Corynebacterium propinquum",
    38301:  "Corynebacterium tuberculostearicum",
    38302:  "Corynebacterium urealyticum",
    38304:  "Corynebacterium jeikeium",
    38305:  "Corynebacterium amycolatum",
    43770:  "Corynebacterium striatum",
    43771:  "Corynebacterium simulans",
    43773:  "Corynebacterium confusum",
    91302:  "Corynebacterium afermentans",
    161879: "Corynebacterium kroppenstedtii",
    170573: "Corynebacterium aurimucosum",
    260085: "Corynebacterium resistens",
    # ── Cutibacterium / Propionibacterium ────────────────────────────────────
    1743460:"Cutibacterium acnes",
    1260:   "Cutibacterium granulosum",
    1261:   "Cutibacterium avidum",
    1743458:"Cutibacterium namnetense",
    1743456:"Cutibacterium humerusii",
    4287:   "Propionibacterium freudenreichii",
    1743457:"Propionibacterium propionicum",
    # ── Malassezia ────────────────────────────────────────────────────────────
    55193:  "Malassezia globosa",
    76773:  "Malassezia restricta",
    55194:  "Malassezia furfur",
    58231:  "Malassezia sympodialis",
    169292: "Malassezia dermatis",
    1231382:"Malassezia nana",
    76774:  "Malassezia pachydermatis",
    1231383:"Malassezia slooffiae",
    1231384:"Malassezia obtusa",
    # ── Micrococcus ───────────────────────────────────────────────────────────
    1270:   "Micrococcus luteus",
    1271:   "Micrococcus antarcticus",
    1272:   "Micrococcus yunnanensis",
    1273:   "Micrococcus flavescens",
    # ── Brevibacterium ────────────────────────────────────────────────────────
    1697:   "Brevibacterium linens",
    38513:  "Brevibacterium casei",
    38513:  "Brevibacterium epidermidis",
    38516:  "Brevibacterium aurantiacum",
    38519:  "Brevibacterium iodinum",
    # ── Dermabacter ───────────────────────────────────────────────────────────
    36808:  "Dermabacter hominis",
    # ── Acinetobacter ─────────────────────────────────────────────────────────
    470:    "Acinetobacter baumannii",
    471:    "Acinetobacter lwoffii",
    472:    "Acinetobacter calcoaceticus",
    718229: "Acinetobacter pittii",
    106654: "Acinetobacter nosocomialis",
    573:    "Acinetobacter haemolyticus",
    28150:  "Acinetobacter johnsonii",
    29430:  "Acinetobacter ursingii",
    106648: "Acinetobacter bereziniae",
    29427:  "Acinetobacter junii",
    40214:  "Acinetobacter radioresistens",
    # ── Moraxella ─────────────────────────────────────────────────────────────
    480:    "Moraxella catarrhalis",
    296:    "Moraxella osloensis",
    292:    "Moraxella nonliquefaciens",
    293:    "Moraxella lacunata",
    # ── Roseomonas ────────────────────────────────────────────────────────────
    159126: "Roseomonas mucosa",
    158890: "Roseomonas gilardii",
    # ── Enhydrobacter ─────────────────────────────────────────────────────────
    225324: "Enhydrobacter aerosaccus",
    # ── Finegoldia ────────────────────────────────────────────────────────────
    150022: "Finegoldia magna",
    # ── Peptoniphilus ─────────────────────────────────────────────────────────
    202956: "Peptoniphilus harei",
    201040: "Peptoniphilus asaccharolyticus",
    29357:  "Peptoniphilus lacrimalis",
    862515: "Peptoniphilus duerdenii",
    862513: "Peptoniphilus tyrrelliae",
    862511: "Peptoniphilus olsenii",
    862509: "Peptoniphilus ivorii",
    # ── Anaerococcus ──────────────────────────────────────────────────────────
    33029:  "Anaerococcus prevotii",
    33031:  "Anaerococcus tetradius",
    33033:  "Anaerococcus vaginalis",
    33036:  "Anaerococcus hydrogenalis",
    33028:  "Anaerococcus lactolyticus",
    33034:  "Anaerococcus murdochii",
    1283316:"Anaerococcus obesiensis",
    # ── Porphyromonas ─────────────────────────────────────────────────────────
    836:    "Porphyromonas gingivalis",
    53246:  "Porphyromonas somerae",
    28445:  "Porphyromonas uenonis",
    # ── Fusobacterium ─────────────────────────────────────────────────────────
    851:    "Fusobacterium nucleatum",
    # ── Rothia ────────────────────────────────────────────────────────────────
    32207:  "Rothia kristinae",
    43675:  "Rothia mucilaginosa",
    38301:  "Rothia dentocariosa",
    # ── Streptococcus ─────────────────────────────────────────────────────────
    1311:   "Streptococcus agalactiae",
    1314:   "Streptococcus pyogenes",
    1303:   "Streptococcus mitis",
    1302:   "Streptococcus anginosus",
    1310:   "Streptococcus dysgalactiae",
    1305:   "Streptococcus mutans",
    1318:   "Streptococcus salivarius",
    # ── Enterococcus ──────────────────────────────────────────────────────────
    1350:   "Enterococcus faecalis",
    1352:   "Enterococcus faecium",
    # ── Pseudomonas ───────────────────────────────────────────────────────────
    287:    "Pseudomonas aeruginosa",
    306:    "Pseudomonas putida",
    294:    "Pseudomonas fluorescens",
    # ── Chryseobacterium ──────────────────────────────────────────────────────
    33960:  "Chryseobacterium gleum",
    29303:  "Chryseobacterium indologenes",
    # ── Stenotrophomonas ──────────────────────────────────────────────────────
    40324:  "Stenotrophomonas maltophilia",
    # ── Kocuria ───────────────────────────────────────────────────────────────
    57493:  "Kocuria rosea",
    57494:  "Kocuria kristinae",
    57495:  "Kocuria varians",
    # ── Clostridiales ─────────────────────────────────────────────────────────
    1502:   "Clostridioides difficile",
    1498:   "Clostridium perfringens",
    # ── Candida ───────────────────────────────────────────────────────────────
    5476:   "Candida albicans",
    5478:   "Candida parapsilosis",
    # ── Escherichia / Klebsiella (opportunistic) ──────────────────────────────
    562:    "Escherichia coli",
    573:    "Klebsiella pneumoniae",
    544:    "Citrobacter freundii",
    # ── Dietzia ───────────────────────────────────────────────────────────────
    37914:  "Dietzia maris",
    # ── Janibacter ────────────────────────────────────────────────────────────
    75185:  "Janibacter limosus",
}

NCBI_DATASETS_API = (
    "https://api.ncbi.nlm.nih.gov/datasets/v2/genome/taxon/"
    "{taxid}/dataset_report?filters.assembly_source=refseq"
    "&filters.exclude_atypical=true&page_size=10"
)

SLEEP = 0.5


def load_existing_taxids(db_path: Path) -> set:
    map_file = db_path / "seqid2taxid.map"
    if not map_file.exists():
        return set()
    taxids = set()
    with open(map_file) as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) >= 2:
                taxids.add(int(parts[1]))
    return taxids


NCBI_FTP_BASE = "https://ftp.ncbi.nlm.nih.gov/genomes/all"


def acc_to_ftp_dir(acc: str) -> str:
    """GCF_014131755.1 → GCF/014/131/755"""
    prefix, rest = acc.split("_", 1)
    digits = rest.split(".")[0]
    return f"{prefix}/{digits[0:3]}/{digits[3:6]}/{digits[6:9]}"


def resolve_accession_for_taxid(taxid: int) -> str | None:
    """Use NCBI datasets API to get the best RefSeq accession for a taxid."""
    import json
    url = NCBI_DATASETS_API.format(taxid=taxid)
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "STAMINA-BIOME-skin-expand/1.0 (research use)"}
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception as e:
        print(f"    [ERROR] API call failed for taxid {taxid}: {e}")
        return None

    reports = data.get("reports", [])
    if not reports:
        return None

    # Prefer reference > representative > any, and complete genome > scaffold
    RANK = {"reference genome": 0, "representative genome": 1, "na": 2}
    LEVEL_RANK = {"Complete Genome": 0, "Chromosome": 1, "Scaffold": 2, "Contig": 3}
    best_acc, best_rank, best_level = None, 99, 99

    for rep in reports:
        acc = rep.get("accession", "")
        if not acc.startswith("GCF_"):
            continue  # RefSeq only
        ainfo = rep.get("assembly_info", {})
        refcat = ainfo.get("refseq_category", "na").lower()
        level = ainfo.get("assembly_level", "Contig")
        rank = RANK.get(refcat, 2)
        level_rank = LEVEL_RANK.get(level, 3)
        if (rank < best_rank) or (rank == best_rank and level_rank < best_level):
            best_acc, best_rank, best_level = acc, rank, level_rank

    return best_acc


def accession_to_ftp_path(acc: str) -> str | None:
    """Resolve GCF accession to full FTP folder path via NCBI directory listing."""
    ftp_dir = f"{NCBI_FTP_BASE}/{acc_to_ftp_dir(acc)}/"
    try:
        with urllib.request.urlopen(ftp_dir, timeout=30) as r:
            html = r.read().decode()
    except Exception as e:
        print(f"    [ERROR] Cannot list FTP dir for {acc}: {e}")
        return None
    import re
    folders = re.findall(rf'href="({re.escape(acc)}[^"]+)/"', html)
    if not folders:
        return None
    folder = folders[0].rstrip("/")
    return f"{ftp_dir}{folder}"


def download_and_prepare(taxid: int, species: str, ftp_base: str,
                          out_dir: Path) -> bool:
    """Download genome, rewrite headers, save to out_dir."""
    ftp_base = ftp_base.rstrip("/")
    basename = ftp_base.split("/")[-1]
    fna_gz_url = f"{ftp_base}/{basename}_genomic.fna.gz"

    out_file = out_dir / f"skin_{taxid}_{basename}_genomic.fna"
    if out_file.exists():
        print(f"  [SKIP] Already present: {out_file.name}")
        return True

    try:
        with urllib.request.urlopen(fna_gz_url, timeout=120) as r:
            gz_data = r.read()
    except Exception as e:
        print(f"  [ERROR] {species} (taxid={taxid}): download failed — {e}")
        return False

    seq_count = 0
    try:
        with gzip.open(gz_data.__class__(gz_data), "rt") if False else \
             gzip.open(__import__("io").BytesIO(gz_data), "rt") as fin, \
             open(out_file, "w") as fout:
            for line in fin:
                if line.startswith(">"):
                    seq_id = line[1:].split()[0].strip()
                    fout.write(f">kraken:taxid|{taxid}|{seq_id}\n")
                    seq_count += 1
                else:
                    fout.write(line)
    except Exception as e:
        print(f"  [ERROR] {species}: header rewrite failed — {e}")
        out_file.unlink(missing_ok=True)
        return False

    print(f"  [OK] {species} (taxid={taxid}): {seq_count} sequences → {out_file.name}")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True, help="Path to skin DB directory")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be downloaded without downloading")
    args = parser.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"[ERROR] DB path not found: {db_path}")
        sys.exit(1)

    out_dir = db_path / "library" / "added"
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n=== STAMINA-BIOME Skin DB Expansion ===")
    print(f"DB:       {db_path}")
    print(f"Output:   {out_dir}")
    print(f"Target species: {len(set(SKIN_TAXA.keys()))}")

    # Load existing taxids to skip what's already present
    existing = load_existing_taxids(db_path)
    print(f"Already in DB: {len(existing)} taxids")

    to_fetch = {taxid: name for taxid, name in SKIN_TAXA.items()
                if taxid not in existing}
    print(f"New taxids to add: {len(to_fetch)}")
    print(f"Estimated final taxid count: ~{len(existing) + len(to_fetch)}")

    if args.dry_run:
        print("\nDry run — would fetch:")
        for taxid, name in sorted(to_fetch.items(), key=lambda x: x[1]):
            print(f"  {taxid:>10}  {name}")
        return

    # Resolve FTP path for each new taxid via NCBI datasets API
    print(f"\nResolving FTP paths via NCBI datasets API ({len(to_fetch)} taxids)...")
    tasks = []
    not_found = []
    for taxid, species in to_fetch.items():
        acc = resolve_accession_for_taxid(taxid)
        time.sleep(SLEEP)
        if acc:
            ftp = accession_to_ftp_path(acc)
            time.sleep(SLEEP)
            if ftp:
                tasks.append((taxid, species, ftp))
                print(f"  [FOUND] {species} (taxid={taxid}) → {acc}")
            else:
                not_found.append((taxid, species))
                print(f"  [MISS]  {species} (taxid={taxid}) — FTP path not resolved for {acc}")
        else:
            not_found.append((taxid, species))
            print(f"  [MISS]  {species} (taxid={taxid}) — not in RefSeq")

    print(f"\nResolved: {len(tasks)} | Not in RefSeq: {len(not_found)}")

    # Download in parallel
    print(f"\nDownloading {len(tasks)} genomes ({args.threads} threads)...")
    ok = fail = 0
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        futures = {
            pool.submit(download_and_prepare, taxid, species, ftp, out_dir): (taxid, species)
            for taxid, species, ftp in tasks
        }
        for future in as_completed(futures):
            taxid, species = futures[future]
            try:
                success = future.result()
                if success:
                    ok += 1
                else:
                    fail += 1
            except Exception as e:
                print(f"  [ERROR] {species}: {e}")
                fail += 1
            time.sleep(SLEEP)

    print(f"\n=== Download complete: {ok} OK | {fail} failed ===")
    print(f"\nNext step — rebuild the database:")
    print(f"  bash databases/skin/rebuild_mypassport.sh --db {db_path}")


if __name__ == "__main__":
    main()
