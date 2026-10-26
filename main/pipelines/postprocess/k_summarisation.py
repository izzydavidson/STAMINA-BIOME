#!/usr/bin/env python3

import os
import sys
import csv
import json
import argparse
from collections import defaultdict
from typing import Any, Dict, List, Optional, Tuple

def log(msg: str):
    print(msg)

def warn(msg: str):
    print(f"[WARN] {msg}")

def script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))

def normalize_site(s: str) -> str:
    s = (s or "").strip().lower()
    s = s.replace(" ", "").replace("_", "").replace("-", "")
    if s in {"vaginal", "vagina"}:
        return "vaginal"
    if s in {"oral", "mouth"}:
        return "oral"
    if s in {"skin"}:
        return "skin"
    return (s or "").strip()

def default_sample_sheet_path() -> str:
    # Backward-compatible fallback: barcode_sites.tsv lives next to this script
    return os.path.join(script_dir(), "barcode_sites.tsv")

def safe_int(x: str, default: int = 0) -> int:
    try:
        return int(float(x))
    except Exception:
        return default

def read_json(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def resolve_path(maybe_path: str, base_dir: str) -> str:
    p = os.path.expandvars(os.path.expanduser(maybe_path or ""))
    if not p:
        return ""
    if os.path.isabs(p):
        return p
    return os.path.normpath(os.path.join(base_dir, p))

def iter_dict_paths(obj: Any, prefix: str = ""):
    """
    Yield (path, key, value) for all dict items recursively.
    path uses dot notation, e.g. "input.sample_sheet".
    """
    if isinstance(obj, dict):
        for k, v in obj.items():
            path = f"{prefix}.{k}" if prefix else str(k)
            yield (path, k, v)
            yield from iter_dict_paths(v, path)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            path = f"{prefix}[{i}]"
            yield from iter_dict_paths(v, path)

def find_sample_sheet_in_config(cfg: Dict[str, Any], cfg_dir: str) -> str:
    """
    Try to discover a sample sheet / barcode_sites TSV path inside config.
    We look for a few common key names anywhere in the JSON.
    """
    candidate_keys = {
        "barcode_sites_tsv",
        "barcode_sites",
        "barcode_map",
        "barcode_map_tsv",
        "sample_sheet",
        "sample_sheet_path",
        "samplesheet",
        "samplesheet_path",
        "barcode_sites_tsv_path",
        "barcode_sites_path",
    }

    # First pass: direct/likely locations
    likely_paths: List[str] = []
    for dotted in [
        ("input", "barcode_sites_tsv"),
        ("input", "sample_sheet"),
        ("run", "barcode_sites_tsv"),
        ("run", "sample_sheet"),
        ("paths", "barcode_sites_tsv"),
        ("paths", "sample_sheet"),
    ]:
        cur: Any = cfg
        ok = True
        for part in dotted:
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                ok = False
                break
        if ok and isinstance(cur, str) and cur.strip():
            likely_paths.append(resolve_path(cur.strip(), cfg_dir))

    for p in likely_paths:
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return p

    # Second pass: scan whole config for candidate key names
    found: List[str] = []
    for _path, key, value in iter_dict_paths(cfg):
        if not isinstance(key, str):
            continue
        if key.strip().lower() in candidate_keys and isinstance(value, str) and value.strip():
            found.append(resolve_path(value.strip(), cfg_dir))

    for p in found:
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return p

    return ""

def load_sample_sheet(tsv_path: str) -> Tuple[Dict[str, str], Dict[str, str], str]:
    """
    Returns:
      name_by_barcode: dict
      site_by_barcode: dict
      default_specimen_type: str
    """
    name_by_barcode: Dict[str, str] = {}
    site_by_barcode: Dict[str, str] = {}
    default_specimen_type = ""

    if not tsv_path or not os.path.isfile(tsv_path) or os.path.getsize(tsv_path) == 0:
        return name_by_barcode, site_by_barcode, default_specimen_type

    with open(tsv_path, "r", newline="") as f:
        reader = csv.reader(f, delimiter="\t")
        rows = list(reader)

    if not rows:
        return name_by_barcode, site_by_barcode, default_specimen_type

    header = [h.strip() for h in rows[0]]
    col = {h.lower(): i for i, h in enumerate(header)}

    def get(row: List[str], *names: str) -> str:
        for n in names:
            i = col.get(n.lower())
            if i is not None and i < len(row):
                return (row[i] or "").strip()
        return ""

    for r in rows[1:]:
        if not r or all((x or "").strip() == "" for x in r):
            continue
        barcode = get(r, "barcode", "sample_id", "id")
        if not barcode:
            continue
        barcode = barcode.strip()
        sample_name = get(r, "sample_name", "name", "sample")
        specimen = get(r, "specimen", "site", "sample_type", "specimen_type")

        if sample_name:
            name_by_barcode[barcode] = sample_name
        if specimen:
            specimen_norm = normalize_site(specimen)
            site_by_barcode[barcode] = specimen_norm
            if not default_specimen_type:
                default_specimen_type = specimen_norm

    return name_by_barcode, site_by_barcode, default_specimen_type

# -----------------------------
# Kraken report parsing
# -----------------------------

def parse_kreport_level(kreport_path: str, target_rank: str):
    """
    Parse all rows with rank_code == target_rank (e.g. 'S' for species, 'G' for genus).

    Kraken2 columns:
      0: percent (rounded, ignored here)
      1: clade_reads
      2: taxon_reads
      3: rank_code
      4: taxid
      5: name
    """
    rows = []

    with open(kreport_path, "r", newline="") as f:
        reader = csv.reader(f, delimiter="\t")
        for parts in reader:
            if len(parts) < 6:
                continue
            rank = (parts[3] or "").strip()
            if rank != target_rank:
                continue

            clade_reads = safe_int(parts[1], 0)
            taxon_reads = safe_int(parts[2], 0)
            taxid = (parts[4] or "").strip()
            name = (parts[5] or "").strip()  # can be indented

            rows.append({
                "rank": rank,
                "taxid": taxid,
                "name": name,
                "clade_reads": clade_reads,
                "taxon_reads": taxon_reads,
            })

    return rows

def compute_fractions(rows, use_clade_reads: bool = True):
    """
    Compute per-sample relative abundances for the selected rank.

    By default this uses clade_reads (often better for "what's in the sample").
    Fractions are normalized within this rank per sample.
    """
    total = sum((r["clade_reads"] if use_clade_reads else r["taxon_reads"]) for r in rows)
    out = []
    for r in rows:
        denom = total if total > 0 else 1
        numer = r["clade_reads"] if use_clade_reads else r["taxon_reads"]
        out.append({
            **r,
            "fraction": float(numer) / float(denom),
        })
    return out

# -----------------------------
# Output writers
# -----------------------------

def write_tidy(out_path: str, tidy_rows, taxon_key: str):
    """
    Tidy table for a level (species/genus):

      sample_id, sample_name, specimen, taxid, <taxon_key>, fraction
    """
    fieldnames = [
        "sample_id",
        "sample_name",
        "specimen",
        "taxid",
        taxon_key,
        "fraction",
    ]
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in tidy_rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})

def write_wide(out_path: str, tidy_rows, taxon_key: str):
    """
    Wide taxa table used by R:

      taxon, <sample_id_1>, <sample_id_2>, ...

    Values are relative abundances (0-1).
    """
    if not tidy_rows:
        return

    sample_ids = sorted({r["sample_id"] for r in tidy_rows})

    taxa_list: List[str] = []
    seen = set()
    for r in tidy_rows:
        tx = r[taxon_key]
        if tx not in seen:
            seen.add(tx)
            taxa_list.append(tx)

    by_taxon = defaultdict(dict)
    for r in tidy_rows:
        tx = r[taxon_key]
        sid = r["sample_id"]
        frac = r.get("fraction", 0.0) or 0.0
        by_taxon[tx][sid] = float(frac)

    fieldnames = ["taxon"] + sample_ids

    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for tx in taxa_list:
            row = {"taxon": tx}
            for sid in sample_ids:
                row[sid] = by_taxon.get(tx, {}).get(sid, 0.0)
            w.writerow(row)

def write_result_table_for_plot(out_path: str, tidy_rows, sample_ids, taxon_key: str):
    """
    Run-level wide table used by the existing R plotting script:

      taxon, <sample_id_1>, <sample_id_2>, ...
    """
    if not tidy_rows:
        return

    taxa_list: List[str] = []
    seen = set()
    for r in tidy_rows:
        tx = r[taxon_key]
        if tx not in seen:
            seen.add(tx)
            taxa_list.append(tx)

    by_taxon = defaultdict(dict)
    for r in tidy_rows:
        tx = r[taxon_key]
        sid = r["sample_id"]
        frac = r.get("fraction", 0.0) or 0.0
        by_taxon[tx][sid] = float(frac)

    fieldnames = ["taxon"] + list(sample_ids)

    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for tx in taxa_list:
            row = {"taxon": tx}
            for sid in sample_ids:
                row[sid] = by_taxon.get(tx, {}).get(sid, 0.0)
            w.writerow(row)

# -----------------------------
# Helpers
# -----------------------------

def find_kreport(sample_path: str, sample_id: str) -> Optional[str]:
    """
    Finder order:
      1) <sample_id>.kreport
      2) any *.kreport
    """
    preferred = os.path.join(sample_path, f"{sample_id}.kreport")
    if os.path.isfile(preferred):
        return preferred

    try:
        files = sorted(os.listdir(sample_path))
    except Exception:
        return None

    kreports = [x for x in files if x.endswith(".kreport")]
    if kreports:
        return os.path.join(sample_path, kreports[0])

    return None

# -----------------------------
# Main
# -----------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Summarise Kraken2 .kreport outputs into tidy + wide taxa tables for R/plots."
    )
    parser.add_argument(
        "taxo_dir",
        help="Directory containing per-sample subdirectories with Kraken2 *.kreport files.",
    )
    parser.add_argument(
        "valencia_dir",
        nargs="?",
        default="",
        help="(ignored; retained for backward compatibility)",
    )
    parser.add_argument(
        "--config",
        default="",
        help="Path to effective_config.json (used to locate sample sheet path).",
    )
    parser.add_argument(
        "--sample-sheet",
        default="",
        help="Explicit path to barcode/sample/specimen TSV (overrides config).",
    )
    parser.add_argument(
        "--run-name",
        default="",
        help="Override run name used in plot table filenames (default: basename of taxo_dir).",
    )
    parser.add_argument(
        "--out-dir",
        default="",
        help="Directory to write outputs (default: taxo_dir).",
    )

    args = parser.parse_args()

    taxo_dir = args.taxo_dir
    if not os.path.isdir(taxo_dir):
        log(f"Taxonomy directory not found: {taxo_dir}")
        return 1

    out_dir = args.out_dir.strip() or taxo_dir
    os.makedirs(out_dir, exist_ok=True)

    if args.valencia_dir:
        warn("Second positional argument (valencia_dir) is ignored by this script.")

    cfg_path = args.config.strip()
    cfg: Dict[str, Any] = {}
    cfg_dir = ""
    if cfg_path:
        if not os.path.isfile(cfg_path):
            warn(f"--config was provided but file does not exist: {cfg_path}")
        else:
            try:
                cfg = read_json(cfg_path)
                cfg_dir = os.path.dirname(os.path.abspath(cfg_path))
            except Exception as e:
                warn(f"Failed to read config JSON: {cfg_path} ({e})")

    # Determine sample sheet path (explicit override > config > legacy fallback)
    sheet_path = ""
    if args.sample_sheet.strip():
        sheet_path = resolve_path(args.sample_sheet.strip(), os.getcwd())
    elif cfg:
        sheet_path = find_sample_sheet_in_config(cfg, cfg_dir)

    if not sheet_path:
        sheet_path = default_sample_sheet_path()

    name_by_barcode, site_by_barcode, default_specimen = load_sample_sheet(sheet_path)

    if os.path.isfile(sheet_path):
        log(f"Using sample sheet for names/specimens: {sheet_path}")
    else:
        log("No sample sheet found; using sample IDs as names/specimens.")

    run_name = args.run_name.strip() or os.path.basename(os.path.normpath(taxo_dir))

    species_tidy_rows = []
    genus_tidy_rows = []
    all_samples_with_kreport: List[str] = []

    for entry in sorted(os.listdir(taxo_dir)):
        sample_path = os.path.join(taxo_dir, entry)
        if not os.path.isdir(sample_path):
            continue

        sample_id = entry

        kreport = find_kreport(sample_path, sample_id)
        if not kreport:
            continue

        all_samples_with_kreport.append(sample_id)

        sample_name = name_by_barcode.get(sample_id, sample_id)
        specimen = site_by_barcode.get(sample_id, default_specimen)

        sp_rows = compute_fractions(parse_kreport_level(kreport, target_rank="S"))
        gn_rows = compute_fractions(parse_kreport_level(kreport, target_rank="G"))

        for srow in sp_rows:
            species_tidy_rows.append({
                "sample_id": sample_id,
                "sample_name": sample_name,
                "specimen": specimen,
                "taxid": srow["taxid"],
                "species": srow["name"],
                "fraction": srow["fraction"],
            })

        for grow in gn_rows:
            genus_tidy_rows.append({
                "sample_id": sample_id,
                "sample_name": sample_name,
                "specimen": specimen,
                "taxid": grow["taxid"],
                "genus": grow["name"],
                "fraction": grow["fraction"],
            })

    if not all_samples_with_kreport:
        warn("No sample subdirectories with kreport files were found.")
        return 0

    plot_sample_ids = sorted(set(all_samples_with_kreport))

    if not species_tidy_rows and not genus_tidy_rows:
        warn("No rank S or rank G rows found in any kreport; nothing to summarise.")
        return 0

    # Output paths (kept backward-compatible)
    species_tidy_out = os.path.join(out_dir, "kraken_species_tidy.csv")
    species_wide_out = os.path.join(out_dir, "kraken_species_wide.csv")
    genus_tidy_out = os.path.join(out_dir, "kraken_genus_tidy.csv")
    genus_wide_out = os.path.join(out_dir, "kraken_genus_wide.csv")

    species_plot_out = os.path.join(out_dir, f"{run_name}_species_result_table.csv")
    genus_plot_out = os.path.join(out_dir, f"{run_name}_genus_result_table.csv")
    species_plot_compat = os.path.join(out_dir, f"{run_name}_result_table.csv")  # legacy name

    if species_tidy_rows:
        write_tidy(species_tidy_out, species_tidy_rows, taxon_key="species")
        write_wide(species_wide_out, species_tidy_rows, taxon_key="species")
        write_result_table_for_plot(species_plot_out, species_tidy_rows, plot_sample_ids, taxon_key="species")
        write_result_table_for_plot(species_plot_compat, species_tidy_rows, plot_sample_ids, taxon_key="species")
        log(f"Wrote tidy species CSV: {species_tidy_out}")
        log(f"Wrote wide species CSV: {species_wide_out}")
        log(f"Wrote species plot table: {species_plot_out}")
        log(f"Wrote species plot table (legacy name): {species_plot_compat}")
    else:
        warn("No species (rank S) rows found in any kreport.")

    if genus_tidy_rows:
        write_tidy(genus_tidy_out, genus_tidy_rows, taxon_key="genus")
        write_wide(genus_wide_out, genus_tidy_rows, taxon_key="genus")
        write_result_table_for_plot(genus_plot_out, genus_tidy_rows, plot_sample_ids, taxon_key="genus")
        log(f"Wrote tidy genus CSV: {genus_tidy_out}")
        log(f"Wrote wide genus CSV: {genus_wide_out}")
        log(f"Wrote genus plot table: {genus_plot_out}")
    else:
        warn("No genus (rank G) rows found in any kreport.")

    log("Samples with kreport (columns in plots):")
    log("  " + ", ".join(plot_sample_ids))

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
