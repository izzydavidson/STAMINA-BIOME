#!/usr/bin/env python3
"""
Prepare CAMISIM simulation genomes for addition to custom Kraken2 databases.

For each body site (gut/oral/skin):
1. Reads ~/camisim_configs/{site}/genome_locations.tsv
2. Queries NCBI datasets API to get species_taxid and organism_name
3. Rewrites FASTA headers to include |kraken:taxid|TAXID| format
4. Saves prepared FASTAs to /tmp/camisim_prep_{site}/
5. Copies prepared FASTAs to <custom_db_base>/{site}/library/added/

Override the custom DB base path with: --db-base /path/to/custom_db
"""

import os
import sys
import time
import shutil
import urllib.request
import urllib.error
import json
import re
from pathlib import Path

import argparse as _argparse
_parser = _argparse.ArgumentParser(add_help=False)
_parser.add_argument("--db-base", default="/Volumes/MyPassport/custom_db")
_args, _ = _parser.parse_known_args()

SITES = ["gut", "oral", "skin"]
CAMISIM_CONFIG_BASE = Path.home() / "camisim_configs"
CAMISIM_GENOME_BASE = Path.home() / "camisim_genomes"
CUSTOM_DB_BASE = Path(_args.db_base)
TMP_BASE = Path("/tmp")
NCBI_API_BASE = "https://api.ncbi.nlm.nih.gov/datasets/v2/genome/accession/{accession}/dataset_report"
API_SLEEP = 1.0  # seconds between NCBI API calls


def extract_gcf_accession(fasta_path: str) -> str | None:
    """Extract GCF/GCA accession from a FASTA file path."""
    filename = os.path.basename(fasta_path)
    # Match GCF_XXXXXXXXX.X or GCA_XXXXXXXXX.X at the start of the filename
    m = re.match(r"(GC[FA]_\d+\.\d+)", filename)
    if m:
        return m.group(1)
    return None


def query_ncbi_taxid(accession: str) -> tuple[int | None, str | None]:
    """
    Query NCBI datasets API for a genome accession.
    Returns (tax_id, organism_name) or (None, None) on failure.
    """
    url = NCBI_API_BASE.format(accession=accession)
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "STAMINA-BIOME-prepare-genomes/1.0 (contact: research use)"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)

        reports = data.get("reports", [])
        if not reports:
            print(f"  [WARN] No reports returned for {accession}", file=sys.stderr)
            return None, None

        organism = reports[0].get("organism", {})
        tax_id = organism.get("tax_id")
        organism_name = organism.get("organism_name")

        # Prefer species_taxid if present (some assemblies have it separate)
        species_taxid = organism.get("species_taxid", tax_id)

        return species_taxid, organism_name

    except urllib.error.HTTPError as e:
        print(f"  [ERROR] HTTP {e.code} for {accession}: {e.reason}", file=sys.stderr)
        return None, None
    except urllib.error.URLError as e:
        print(f"  [ERROR] URL error for {accession}: {e.reason}", file=sys.stderr)
        return None, None
    except json.JSONDecodeError as e:
        print(f"  [ERROR] JSON parse error for {accession}: {e}", file=sys.stderr)
        return None, None
    except Exception as e:
        print(f"  [ERROR] Unexpected error for {accession}: {e}", file=sys.stderr)
        return None, None


def rewrite_fasta_headers(input_path: Path, output_path: Path, taxid: int) -> int:
    """
    Rewrite FASTA headers to prepend kraken taxid tag.
    New header format: >kraken:taxid|TAXID|original_id [rest of description]
    Returns number of sequences rewritten.
    """
    seq_count = 0
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(input_path, "r") as fin, open(output_path, "w") as fout:
        for line in fin:
            if line.startswith(">"):
                # Strip the leading ">" and any trailing whitespace
                rest = line[1:].rstrip()
                # Split into seq_id and optional description
                parts = rest.split(None, 1)
                seq_id = parts[0]
                description = (" " + parts[1]) if len(parts) > 1 else ""
                # Write new header: >kraken:taxid|TAXID|original_seq_id [description]
                fout.write(f">kraken:taxid|{taxid}|{seq_id}{description}\n")
                seq_count += 1
            else:
                fout.write(line)

    return seq_count


def read_genome_locations(tsv_path: Path) -> list[tuple[str, str]]:
    """
    Parse genome_locations.tsv.
    Format: genome_label<TAB>fasta_path (no header row).
    Returns list of (label, fasta_path) tuples.
    """
    entries = []
    with open(tsv_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                print(f"  [WARN] Skipping malformed line: {line!r}", file=sys.stderr)
                continue
            label = parts[0]
            fasta_path = parts[1]
            entries.append((label, fasta_path))
    return entries


def process_site(site: str) -> list[dict]:
    """
    Process all genomes for a given body site.
    Returns list of summary dicts.
    """
    print(f"\n{'='*60}")
    print(f"  Processing site: {site.upper()}")
    print(f"{'='*60}")

    tsv_path = CAMISIM_CONFIG_BASE / site / "genome_locations.tsv"
    if not tsv_path.exists():
        print(f"  [ERROR] genome_locations.tsv not found at {tsv_path}", file=sys.stderr)
        return []

    tmp_dir = TMP_BASE / f"camisim_prep_{site}"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    dest_dir = CUSTOM_DB_BASE / site / "library" / "added"
    if not dest_dir.exists():
        print(f"  [ERROR] Destination directory does not exist: {dest_dir}", file=sys.stderr)
        print(f"  [INFO]  Creating it now...", file=sys.stderr)
        dest_dir.mkdir(parents=True, exist_ok=True)

    entries = read_genome_locations(tsv_path)
    print(f"  Found {len(entries)} genome(s) in {tsv_path.name}")

    summaries = []
    first_api_call = True

    for label, fasta_path_str in entries:
        fasta_path = Path(fasta_path_str)
        print(f"\n  Genome: {label}")
        print(f"    Source: {fasta_path}")

        if not fasta_path.exists():
            print(f"    [ERROR] FASTA file not found, skipping.", file=sys.stderr)
            summaries.append({
                "site": site, "label": label, "accession": "?",
                "taxid": None, "organism": None, "status": "FASTA_NOT_FOUND"
            })
            continue

        accession = extract_gcf_accession(fasta_path_str)
        if not accession:
            print(f"    [ERROR] Could not extract GCF accession from filename, skipping.", file=sys.stderr)
            summaries.append({
                "site": site, "label": label, "accession": "?",
                "taxid": None, "organism": None, "status": "NO_ACCESSION"
            })
            continue

        print(f"    Accession: {accession}")

        # Rate-limit NCBI API calls
        if not first_api_call:
            time.sleep(API_SLEEP)
        first_api_call = False

        taxid, organism_name = query_ncbi_taxid(accession)

        if taxid is None:
            print(f"    [ERROR] Failed to get taxid from NCBI, skipping.", file=sys.stderr)
            summaries.append({
                "site": site, "label": label, "accession": accession,
                "taxid": None, "organism": organism_name, "status": "API_FAILED"
            })
            continue

        print(f"    Organism: {organism_name}")
        print(f"    TaxID:    {taxid}")

        # Prepare output filename — use original filename
        out_filename = fasta_path.name
        tmp_out = tmp_dir / out_filename

        # Rewrite FASTA headers
        seq_count = rewrite_fasta_headers(fasta_path, tmp_out, taxid)
        print(f"    Headers rewritten: {seq_count} sequence(s) -> {tmp_out}")

        # Copy to destination
        dest_path = dest_dir / out_filename
        shutil.copy2(tmp_out, dest_path)
        print(f"    Copied to: {dest_path}")

        summaries.append({
            "site": site,
            "label": label,
            "accession": accession,
            "taxid": taxid,
            "organism": organism_name,
            "seq_count": seq_count,
            "tmp_path": str(tmp_out),
            "dest_path": str(dest_path),
            "status": "OK"
        })

    return summaries


def print_summary(all_summaries: list[dict]) -> None:
    """Print a formatted summary table of all processed genomes."""
    print(f"\n{'='*80}")
    print("  SUMMARY")
    print(f"{'='*80}")
    print(f"  {'SITE':<6}  {'LABEL':<35}  {'ACCESSION':<20}  {'TAXID':<10}  {'STATUS'}")
    print(f"  {'-'*6}  {'-'*35}  {'-'*20}  {'-'*10}  {'-'*12}")

    ok_count = 0
    fail_count = 0

    for s in all_summaries:
        taxid_str = str(s["taxid"]) if s["taxid"] else "N/A"
        print(f"  {s['site']:<6}  {s['label']:<35}  {s['accession']:<20}  {taxid_str:<10}  {s['status']}")
        if s["status"] == "OK":
            ok_count += 1
        else:
            fail_count += 1

    print(f"\n  Total: {len(all_summaries)} genome(s) | Success: {ok_count} | Failed: {fail_count}")

    if ok_count > 0:
        print(f"\n  Successfully prepared genomes by site:")
        for site in SITES:
            site_ok = [s for s in all_summaries if s["site"] == site and s["status"] == "OK"]
            if site_ok:
                print(f"\n    {site.upper()} ({len(site_ok)} genome(s)):")
                for s in site_ok:
                    print(f"      - {s['organism']} (taxid={s['taxid']}, {s['accession']})")
                    print(f"        -> {s['dest_path']}")


def main():
    print("STAMINA-BIOME: Prepare CAMISIM genomes for Kraken2 custom DBs")
    print(f"Sites: {', '.join(SITES)}")
    print(f"Source configs: {CAMISIM_CONFIG_BASE}")
    print(f"Destination base: {CUSTOM_DB_BASE}")

    # Verify destination volume is mounted
    if not CUSTOM_DB_BASE.exists():
        print(f"\n[FATAL] Custom DB base not accessible: {CUSTOM_DB_BASE}", file=sys.stderr)
        print("[FATAL] Is the MyPassport USB drive mounted?", file=sys.stderr)
        sys.exit(1)

    all_summaries = []
    for site in SITES:
        summaries = process_site(site)
        all_summaries.extend(summaries)

    print_summary(all_summaries)

    # Exit with error code if any failures
    failures = [s for s in all_summaries if s["status"] != "OK"]
    if failures:
        print(f"\n[WARN] {len(failures)} genome(s) failed — review errors above before rebuilding DBs.")
        sys.exit(1)
    else:
        print(f"\n[OK] All genomes prepared successfully. Ready to run rebuild_custom_dbs.sh")
        sys.exit(0)


if __name__ == "__main__":
    main()
