#!/usr/bin/env python3
"""
add_ncbi_strains.py — Download additional NCBI RefSeq genome assemblies
and add them to the custom Kraken2 DB library with correct taxid headers.

Usage:
    python3 add_ncbi_strains.py [--db-base /path/to/custom_db]

Hardcoded list of accessions / taxids / target DBs for the worst-accuracy
species across gut, oral, skin custom databases.
"""

import os, sys, gzip, urllib.request, urllib.error, shutil, tempfile, time, re, argparse

_parser = argparse.ArgumentParser(add_help=False)
_parser.add_argument("--db-base", default="/Volumes/MyPassport/custom_db")
_args, _ = _parser.parse_known_args()
CUSTOM_DB_BASE = _args.db_base

# Target accessions per site / species
# Format: (GCF_accession, species_taxid, db_site, species_name)
TARGETS = [
    # ── GUT: Bacteroides thetaiotaomicron (taxid 818) ──────────────────────────
    ("GCF_014131755.1", 818,  "gut",  "Bacteroides thetaiotaomicron"),
    ("GCF_022453665.1", 818,  "gut",  "Bacteroides thetaiotaomicron"),
    ("GCF_019857385.1", 818,  "gut",  "Bacteroides thetaiotaomicron"),
    ("GCF_019896115.1", 818,  "gut",  "Bacteroides thetaiotaomicron"),
    # ── GUT: Helicobacter pylori (taxid 210) ────────────────────────────────────
    ("GCF_025998455.1", 210,  "gut",  "Helicobacter pylori"),
    ("GCF_003050665.1", 210,  "gut",  "Helicobacter pylori"),
    ("GCF_004295525.1", 210,  "gut",  "Helicobacter pylori"),
    ("GCF_900478295.1", 210,  "gut",  "Helicobacter pylori"),
    # ── GUT: Lactobacillus gasseri (taxid 1596) ─────────────────────────────────
    ("GCF_040050875.1", 1596, "gut",  "Lactobacillus gasseri"),
    ("GCF_002158885.1", 1596, "gut",  "Lactobacillus gasseri"),
    ("GCF_013363915.1", 1596, "gut",  "Lactobacillus gasseri"),
    ("GCF_017840575.1", 1596, "gut",  "Lactobacillus gasseri"),
    # ── SKIN: Staphylococcus epidermidis (taxid 1282) ───────────────────────────
    ("GCF_006094375.1", 1282, "skin", "Staphylococcus epidermidis"),
    ("GCF_006742205.1", 1282, "skin", "Staphylococcus epidermidis"),
    ("GCF_019329745.1", 1282, "skin", "Staphylococcus epidermidis"),
    ("GCF_019329665.1", 1282, "skin", "Staphylococcus epidermidis"),
    # ── ORAL: Streptococcus oralis (taxid 1303) ─────────────────────────────────
    ("GCF_900637025.1", 1303, "oral", "Streptococcus oralis"),
    ("GCF_016127555.1", 1303, "oral", "Streptococcus oralis"),
    ("GCF_018985485.2", 1303, "oral", "Streptococcus oralis"),
    ("GCF_023611505.1", 1303, "oral", "Streptococcus oralis"),
]

NCBI_FTP_BASE = "https://ftp.ncbi.nlm.nih.gov/genomes/all"


def acc_to_ftp_path(acc):
    """GCF_014131755.1 → GCF/014/131/755"""
    parts = acc.split("_")[1].split(".")[0]   # "014131755"
    return f"{acc.split('_')[0]}/{parts[0:3]}/{parts[3:6]}/{parts[6:9]}"


def fetch_asm_report(acc):
    """Return (fna_filename_stem, asm_name) or raise."""
    ftp_dir = f"{NCBI_FTP_BASE}/{acc_to_ftp_path(acc)}"
    # List directory via HTTPS to find the versioned folder
    url = f"https://ftp.ncbi.nlm.nih.gov/genomes/all/{acc_to_ftp_path(acc)}/"
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            html = r.read().decode()
    except Exception as e:
        raise RuntimeError(f"Cannot list FTP dir for {acc}: {e}")

    # Find the accession+version folder name
    folders = re.findall(rf'href="({acc}[^"]+)/"', html)
    if not folders:
        raise RuntimeError(f"No folder found for {acc} at {url}")
    folder = folders[0].rstrip("/")
    return folder


def download_genome(acc, taxid, site, species_name):
    out_dir = os.path.join(CUSTOM_DB_BASE, site, "library", "added")
    os.makedirs(out_dir, exist_ok=True)

    safe_name = acc.replace(".", "_")
    out_fna   = os.path.join(out_dir, f"ncbi_{safe_name}.fna")
    if os.path.exists(out_fna):
        print(f"  [SKIP] Already present: {out_fna}")
        return True

    print(f"  Resolving FTP path for {acc} ...")
    try:
        folder = fetch_asm_report(acc)
    except Exception as e:
        print(f"  [ERROR] {e}")
        return False

    ftp_dir_full = f"{NCBI_FTP_BASE}/{acc_to_ftp_path(acc)}/{folder}"
    fna_gz_url   = f"{ftp_dir_full}/{folder}_genomic.fna.gz"
    print(f"  Downloading: {fna_gz_url}")

    try:
        with tempfile.NamedTemporaryFile(suffix=".fna.gz", delete=False) as tmp:
            tmp_path = tmp.name
        urllib.request.urlretrieve(fna_gz_url, tmp_path)
    except Exception as e:
        print(f"  [ERROR] Download failed: {e}")
        return False

    # Rewrite FASTA headers to kraken:taxid|TAXID|original
    print(f"  Rewriting headers → taxid {taxid}")
    seq_count = 0
    try:
        with gzip.open(tmp_path, "rt") as fin, open(out_fna, "w") as fout:
            for line in fin:
                if line.startswith(">"):
                    orig = line[1:].split()[0].strip()
                    fout.write(f">kraken:taxid|{taxid}|{orig}\n")
                    seq_count += 1
                else:
                    fout.write(line)
    except Exception as e:
        print(f"  [ERROR] Header rewrite failed: {e}")
        os.unlink(out_fna)
        return False
    finally:
        os.unlink(tmp_path)

    print(f"  Written: {out_fna}  ({seq_count} sequences)")
    return True


def main():
    print(f"Adding {len(TARGETS)} assemblies to custom DBs\n")
    results = {"ok": [], "fail": []}

    for acc, taxid, site, sp in TARGETS:
        print(f"\n── {sp} ({acc}) → {site} DB ──")
        ok = download_genome(acc, taxid, site, sp)
        (results["ok"] if ok else results["fail"]).append(acc)
        time.sleep(0.5)   # be polite to NCBI

    print(f"\n{'='*60}")
    print(f"Success: {len(results['ok'])}  |  Failed: {len(results['fail'])}")
    if results["fail"]:
        print("Failed accessions:", results["fail"])

    # Show counts per site
    for site in ["gut", "oral", "skin"]:
        added_dir = os.path.join(CUSTOM_DB_BASE, site, "library", "added")
        n = len([f for f in os.listdir(added_dir) if f.endswith(".fna")]) if os.path.isdir(added_dir) else 0
        print(f"  {site} library/added: {n} .fna files")


if __name__ == "__main__":
    main()
