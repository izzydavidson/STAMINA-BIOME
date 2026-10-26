#!/usr/bin/env python3
import csv
import os
import re
import sys
from collections import defaultdict


def eprint(msg):
    print(msg, file=sys.stderr)


def try_float(x):
    try:
        return float(x)
    except Exception:
        return None


def normalize(s):
    return (s or "").strip().lower()


def parse_param_from_filename(filename, run_base):
    # Extract <run_base>_<num>param from anywhere in the filename
    # e.g. vaginal_testrun_0.26param_valencia_out.csv -> 0.26
    m = re.search(r"%s_(\d+(?:\.\d+)?)param" % re.escape(run_base), filename)
    if not m:
        return None
    return m.group(1)


def looks_like_valencia_output_csv(fn):
    low = fn.lower()
    if not low.endswith(".csv"):
        return False
    if "valencia" not in low:
        return False
    if "input" in low:
        return False
    # Usually contains "valencia_out" prefix, but allow a few variants
    markers = ["valencia_out", "valenciaoutput", "valencia_output", "valencia_result", "valencia_results"]
    return any(m in low for m in markers)


def detect_column(header, desired_names):
    # Case-insensitive exact match across a list of desired names
    header_map = {normalize(h): h for h in header}
    for d in desired_names:
        key = normalize(d)
        if key in header_map:
            return header_map[key]
    return None


def detect_cst_column(header):
    # Prefer known CST-like columns, otherwise any column containing "cst"
    preferred = [
        "CST",
        "CST_Assignment",
        "CST_assignment",
        "Nearest_CST",
        "NearestCST",
        "CST_Closest",
        "Closest_CST",
    ]
    col = detect_column(header, preferred)
    if col:
        return col

    # Fallback: any column that contains "cst"
    for h in header:
        if "cst" in normalize(h):
            return h
    return None


def load_valencia_output(path):
    """
    Returns list of dict rows with keys: sample_id, cst
    """
    rows = []
    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            return rows

        header = reader.fieldnames

        sample_col = detect_column(header, ["sampleID", "SampleID", "sampleid"])
        cst_col = detect_cst_column(header)

        if not sample_col or not cst_col:
            return rows

        for r in reader:
            sid = (r.get(sample_col) or "").strip()
            cst = (r.get(cst_col) or "").strip()
            if not sid:
                continue
            if not cst:
                cst = "Unassigned"
            rows.append({"sample_id": sid, "cst": cst})
    return rows


def main():
    if len(sys.argv) < 3:
        eprint("Usage: valencia_cst_collate.py <VALENCIA_RESULTS_DIR> <RUN_BASE>")
        return 2

    results_dir = sys.argv[1]
    run_base = sys.argv[2]

    if not os.path.isdir(results_dir):
        eprint("ERROR: results dir not found: %s" % results_dir)
        return 2

    files = sorted(os.listdir(results_dir))

    # Gather candidate output CSVs for this base
    candidates = []
    input_count = 0
    for fn in files:
        if not fn.startswith(run_base):
            continue
        low = fn.lower()
        if low.endswith(".csv") and "valencia" in low and "input" in low:
            input_count += 1
            continue
        if not looks_like_valencia_output_csv(fn):
            continue

        param = parse_param_from_filename(fn, run_base)
        if not param:
            continue

        candidates.append((param, os.path.join(results_dir, fn)))

    if not candidates:
        if input_count > 0:
            print(
                "Found %d VALENCIA input CSV(s) for base '%s' but 0 VALENCIA output CSV(s) to collate."
                % (input_count, run_base)
            )
            print("I look for output files containing 'valencia_out' (or similar) and ending with .csv.")
            print("List a few files in the directory to confirm output naming:")
            print("  ls -1 %s | grep -i '%s' | head -n 50" % (results_dir, run_base))
            return 0

        print("No VALENCIA inputs/outputs found for base '%s' in %s" % (run_base, results_dir))
        return 0

    # Sort by numeric param
    def sort_key(item):
        p = item[0]
        fp = try_float(p)
        return (fp is None, fp if fp is not None else 9999.0, p)

    candidates.sort(key=sort_key)

    # Collect long rows
    long_rows = []
    skipped = 0
    for param, path in candidates:
        per = load_valencia_output(path)
        if not per:
            skipped += 1
            continue
        for r in per:
            long_rows.append({"param": param, "SampleID": r["sample_id"], "CST": r["cst"]})

    if not long_rows:
        eprint("ERROR: Found output files but could not extract SampleID + CST from any of them.")
        eprint("Check one output header, e.g.:")
        eprint("  head -n 1 %s" % candidates[0][1])
        return 1

    # Write long format
    long_out = os.path.join(results_dir, "%s_valencia_cst_by_sample_long.csv" % run_base)
    with open(long_out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["param", "SampleID", "CST"])
        w.writeheader()
        w.writerows(long_rows)

    # Count per param + CST
    counts = defaultdict(lambda: defaultdict(int))
    totals = defaultdict(int)
    for r in long_rows:
        p = r["param"]
        c = r["CST"]
        counts[p][c] += 1
        totals[p] += 1

    # Write counts table
    counts_out = os.path.join(results_dir, "%s_valencia_cst_counts_by_param.csv" % run_base)
    with open(counts_out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["param", "CST", "count", "total"])
        w.writeheader()
        for p in sorted(totals.keys(), key=lambda x: sort_key((x, ""))):
            total = totals[p]
            for cst, n in sorted(counts[p].items(), key=lambda kv: (-kv[1], kv[0])):
                w.writerow({"param": p, "CST": cst, "count": n, "total": total})

    # Write proportions table
    prop_out = os.path.join(results_dir, "%s_valencia_cst_proportions_by_param.csv" % run_base)
    with open(prop_out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["param", "CST", "proportion"])
        w.writeheader()
        for p in sorted(totals.keys(), key=lambda x: sort_key((x, ""))):
            total = totals[p]
            for cst, n in sorted(counts[p].items(), key=lambda kv: (-kv[1], kv[0])):
                w.writerow({"param": p, "CST": cst, "proportion": (float(n) / float(total)) if total else 0.0})

    print("Collation complete.")
    print("  Outputs scanned: %d (skipped unreadable: %d)" % (len(candidates), skipped))
    print("  Wrote: %s" % long_out)
    print("  Wrote: %s" % counts_out)
    print("  Wrote: %s" % prop_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

