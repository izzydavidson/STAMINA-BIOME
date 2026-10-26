#!/usr/bin/env python3
"""
apply_sample_map.py

Renames barcode sample IDs to user-defined names in all postprocess CSV outputs.
Reads sample_map from the pipeline config JSON and applies it to every relevant
CSV file found in the run output directory.

Only runs when sample_map is present in the config. Safe to call when no
sample_map is configured — exits immediately with code 0.

Matching strategy mirrors the R apply_sample_map() function:
  Extract the trailing _(barcodeNN) from the sample_id value, look it up
  in the sample_map, replace the entire cell value with the mapped name.

  e.g. "0a179259_EXP-PBC001_barcode04" -> "VM04"
       "barcode04"                       -> "VM04"
"""

import csv
import json
import os
import re
import shutil
import sys


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg):
    print(f"[apply_sample_map] {msg}", flush=True)


def sanitize_run_id(raw):
    """Match the sanitization performed by pipeline_modal_server.R."""
    s = raw.lower()
    s = re.sub(r"[^a-z0-9_-]", "", s)
    s = re.sub(r"^-+|-+$", "", s)
    return s


def extract_barcode(value):
    """
    Return the normalised barcode key from a sample_id string, or None.
    Matches trailing _(barcodeNN) first, then any occurrence as fallback.
    e.g. "run_EXP-PBC001_barcode04"  -> "barcode04"
         "barcode04"                  -> "barcode04"
    """
    # Prefer trailing match (same logic as R: sub(".*_(barcode[0-9]+)$", "\\1", ...))
    m = re.search(r"_(barcode\d+)$", value, re.IGNORECASE)
    if m:
        return m.group(1).lower()
    # Fallback: barcode anywhere in the string
    m = re.search(r"\b(barcode\d+)\b", value, re.IGNORECASE)
    if m:
        return m.group(1).lower()
    return None


def apply_map_to_csv(fpath, sample_map):
    """
    Read a CSV, rename barcode* values in the sample_id column to mapped names.
    Returns the number of rows renamed, or 0 if nothing changed.
    Writes atomically via a .tmp file.
    """
    try:
        with open(fpath, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            if not reader.fieldnames:
                return 0

            # Find a sample-id column (case-insensitive priority order)
            sample_col = None
            for candidate in ("sample_id", "sample", "barcode"):
                for fn in reader.fieldnames:
                    if fn.lower() == candidate:
                        sample_col = fn
                        break
                if sample_col:
                    break

            if sample_col is None:
                return 0

            rows = list(reader)
            fieldnames = list(reader.fieldnames)

        changed = 0
        for row in rows:
            val = row[sample_col]
            bc = extract_barcode(val)
            if bc and bc in sample_map:
                row[sample_col] = sample_map[bc]
                changed += 1

        if changed == 0:
            return 0

        tmp_path = fpath + ".apply_sample_map.tmp"
        with open(tmp_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        shutil.move(tmp_path, fpath)
        return changed

    except Exception as e:
        log(f"Error processing {fpath}: {e}")
        return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    config_file = None
    i = 0
    while i < len(args):
        if args[i] == "--config" and i + 1 < len(args):
            config_file = args[i + 1]
            i += 2
        else:
            i += 1

    if not config_file or not os.path.isfile(config_file):
        log("No valid --config provided. Skipping.")
        sys.exit(0)

    try:
        with open(config_file, encoding="utf-8") as f:
            config = json.load(f)
    except Exception as e:
        log(f"Failed to parse config: {e}. Skipping.")
        sys.exit(0)

    sample_map = config.get("sample_map")
    if not sample_map:
        log("No sample_map in config. Skipping.")
        sys.exit(0)

    # Normalise map keys to lowercase
    sample_map = {k.lower(): v for k, v in sample_map.items()}
    log(f"Applying sample_map: {sample_map}")

    pipeline_id = config.get("pipeline_id", "")
    work_dir    = config.get("run", {}).get("work_dir", "")
    run_id_raw  = config.get("run", {}).get("run_id", "")
    run_id      = sanitize_run_id(run_id_raw)

    run_dir = os.path.join(work_dir, run_id)
    mod_dir = os.path.join(run_dir, pipeline_id)

    # Ordered list: rename source tidy CSVs first so R re-runs read clean data
    candidate_dirs = [
        os.path.join(mod_dir, "results", "postprocess"),   # SOURCE: tidy CSVs
        os.path.join(run_dir, "results", "tables"),
        os.path.join(run_dir, "results", "plots"),
        os.path.join(run_dir, "final_results", "tables"),
        os.path.join(run_dir, "final_results", "plots"),
    ]

    total_files = 0
    total_rows  = 0
    for d in candidate_dirs:
        if not os.path.isdir(d):
            continue
        for fname in sorted(os.listdir(d)):
            if not fname.lower().endswith(".csv"):
                continue
            fpath = os.path.join(d, fname)
            n = apply_map_to_csv(fpath, sample_map)
            if n:
                total_files += 1
                total_rows  += n
                log(f"  Renamed {n} row(s) in {os.path.relpath(fpath, run_dir)}")

    log(f"Done — {total_rows} row(s) renamed across {total_files} file(s).")
    sys.exit(0)


if __name__ == "__main__":
    main()
