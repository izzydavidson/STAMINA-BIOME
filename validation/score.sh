#!/usr/bin/env bash
# =============================================================================
# STAMINA-BIOME Sweep Scorer
# Scores a pipeline kraken_species_tidy.csv against a CAMI ground truth file.
# Prints a full report to stdout and appends one TSV row to the scores file.
#
# Usage:
#   ./score.sh <results_csv> <ground_truth_txt> <run_id> <dataset> \
#              <confidence> <mhg> <scores_tsv>
# =============================================================================

RESULTS_CSV="${1:-}"
GROUND_TRUTH="${2:-}"
RUN_ID="${3:-unknown}"
DATASET="${4:-unknown}"
CONFIDENCE="${5:-?}"
MHG="${6:-?}"
SCORES_TSV="${7:-/dev/null}"
READLEN="${8:-}"      # optional — included in TSV row if provided

if [[ -z "${RESULTS_CSV}" || -z "${GROUND_TRUTH}" ]]; then
  echo "Usage: $0 <results_csv> <ground_truth_txt> <run_id> <dataset> <confidence> <mhg> <scores_tsv> [readlen]"
  exit 1
fi

if [[ ! -f "${RESULTS_CSV}" ]]; then
  echo "[score] Results file not found: ${RESULTS_CSV}" >&2
  exit 1
fi

if [[ ! -f "${GROUND_TRUTH}" ]]; then
  echo "[score] Ground truth not found: ${GROUND_TRUTH}" >&2
  exit 1
fi

python3 - \
  "${RESULTS_CSV}" "${GROUND_TRUTH}" "${RUN_ID}" \
  "${DATASET}" "${CONFIDENCE}" "${MHG}" "${SCORES_TSV}" "${READLEN}" \
<<'PYEOF'
import sys, csv

results_csv  = sys.argv[1]
ground_truth = sys.argv[2]
run_id       = sys.argv[3]
dataset      = sys.argv[4]
confidence   = sys.argv[5]
mhg          = sys.argv[6]
scores_tsv   = sys.argv[7]
readlen      = sys.argv[8] if len(sys.argv) > 8 else ""

# ── Parse ground truth (species rows only) ────────────────────────────────────
gt = {}
with open(ground_truth) as f:
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("@") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        taxid, rank, taxpathsn, pct = parts[0], parts[1], parts[3], parts[4]
        if rank != "species":
            continue
        name = taxpathsn.rstrip("|").split("|")[-1].strip()
        try:
            gt[int(taxid)] = (name, float(pct) / 100.0)
        except ValueError:
            pass

# ── Parse pipeline output (barcode00, species rows) ──────────────────────────
pipeline = {}
with open(results_csv) as f:
    reader = csv.DictReader(f)
    for row in reader:
        sid = row.get("sample_id", "").strip()
        if sid not in ("barcode00", "sample"):
            continue
        rank = row.get("rank", "species")
        if rank and rank != "species":
            continue
        try:
            taxid = int(row["taxid"])
            frac  = float(row["fraction"])
            # take max if barcode00 and sample differ (they shouldn't)
            pipeline[taxid] = max(pipeline.get(taxid, 0.0), frac)
        except (ValueError, KeyError):
            pass

# ── Compute metrics ───────────────────────────────────────────────────────────
total_ae  = 0.0
detected  = 0
for taxid, (name, gt_frac) in gt.items():
    pred = pipeline.get(taxid, 0.0)
    total_ae += abs(pred - gt_frac)
    if pred > 0:
        detected += 1

mae = total_ae / len(gt) if gt else 0.0
recovery_pct = 100.0 * detected / len(gt) if gt else 0.0
false_positives = [(tid, f) for tid, f in pipeline.items()
                   if tid not in gt and f > 0.0001]

# ── Print full report ─────────────────────────────────────────────────────────
print(f"\n{'─'*72}")
print(f"  {run_id}  |  dataset={dataset}  conf={confidence}  mhg={mhg}")
print(f"{'─'*72}")
print(f"  MAE              : {mae*100:.3f}%")
print(f"  Species detected : {detected}/{len(gt)}  ({recovery_pct:.0f}%)")
print(f"  False positives  : {len(false_positives)}")
print()
print(f"  {'Species':<45} {'Truth%':>7}  {'Pipeline%':>9}  {'Error%':>8}")
print(f"  {'─'*45} {'─'*7}  {'─'*9}  {'─'*8}")

for taxid, (name, gt_frac) in sorted(gt.items(), key=lambda x: -x[1][1]):
    pred = pipeline.get(taxid, 0.0)
    err  = pred - gt_frac
    flag = "✓" if abs(err) < 0.02 else ("↑" if err > 0 else "↓")
    print(f"  {name:<45} {gt_frac*100:>6.2f}%  {pred*100:>8.2f}%  {err*100:>+7.2f}% {flag}")

if false_positives:
    print(f"\n  False positives:")
    for taxid, frac in sorted(false_positives, key=lambda x: -x[1]):
        name = f"taxid={taxid}"
        print(f"    {name:<20}  {frac*100:.3f}%")

print()

# ── Append TSV row ────────────────────────────────────────────────────────────
# Check if this run_id already has a row (avoid duplicates on re-run)
existing = set()
try:
    with open(scores_tsv) as f:
        for line in f:
            parts = line.split("\t")
            if parts:
                existing.add(parts[0].strip())
except FileNotFoundError:
    pass

if run_id not in existing and scores_tsv != "/dev/null":
    with open(scores_tsv, "a") as f:
        if readlen:
            f.write(f"{run_id}\t{dataset}\t{confidence}\t{mhg}\t{readlen}\t"
                    f"{mae*100:.3f}\t{detected}\t{len(gt)}\t"
                    f"{recovery_pct:.0f}\t{len(false_positives)}\n")
        else:
            f.write(f"{run_id}\t{dataset}\t{confidence}\t{mhg}\t"
                    f"{mae*100:.3f}\t{detected}\t{len(gt)}\t"
                    f"{recovery_pct:.0f}\t{len(false_positives)}\n")
    print(f"  [score] Appended to {scores_tsv}")

PYEOF
