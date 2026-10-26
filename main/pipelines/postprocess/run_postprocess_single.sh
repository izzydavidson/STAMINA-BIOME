#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pipelines/postprocess/run_postprocess_single.sh --run-dir <DIR> --config <config.json> [--dry-run]

What it does (single-run):
  - Reads: <run-dir>/sr_amp/outputs.json
  - Creates: <run-dir>/sr_amp/final/
  - Copies selected already-generated outputs into final/
  - Generates missing plots (heatmap / stacked bar / pie) from QIIME2 exported TSVs
  - Writes: <run-dir>/sr_amp/final/manifest.json

Selection logic:
  - If config.output.selected contains entries other than "default", those IDs are used.
    Example IDs:
      qc.multiqc
      qc.qiime2_demux_qzv
      tables.feature_table_tsv
      tables.taxonomy_tsv
      diversity.alpha_tsv
      valencia.output_csv
      taxa_plots.stacked_bar
      taxa_plots.heatmap
      taxa_plots.pie
  - Otherwise, uses config.output.options flags (1/0).

EOF
}

RUN_DIR=""
CONFIG_PATH=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${RUN_DIR}" ]]; then echo "ERROR: --run-dir is required" >&2; usage; exit 2; fi
if [[ -z "${CONFIG_PATH}" ]]; then echo "ERROR: --config is required" >&2; usage; exit 2; fi
if [[ ! -d "${RUN_DIR}" ]]; then echo "ERROR: run dir not found: ${RUN_DIR}" >&2; exit 2; fi
if [[ ! -f "${CONFIG_PATH}" ]]; then echo "ERROR: config not found: ${CONFIG_PATH}" >&2; exit 2; fi
if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq is required but not found in PATH" >&2; exit 2; fi
if ! command -v python3 >/dev/null 2>&1; then echo "ERROR: python3 is required but not found in PATH" >&2; exit 2; fi

RUN_DIR="$(python3 - "${RUN_DIR}" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"

MODULE_DIR="${RUN_DIR}/sr_amp"
if [[ ! -d "${MODULE_DIR}" ]]; then
  echo "ERROR: Expected sr_amp module folder not found at: ${MODULE_DIR}" >&2
  exit 2
fi

OUTPUTS_JSON="${MODULE_DIR}/outputs.json"
if [[ ! -f "${OUTPUTS_JSON}" ]]; then
  echo "ERROR: sr_amp outputs.json not found at: ${OUTPUTS_JSON}" >&2
  exit 2
fi

FINAL_DIR="${MODULE_DIR}/final"
FINAL_PLOTS_DIR="${FINAL_DIR}/plots"
MANIFEST_JSON="${FINAL_DIR}/manifest.json"
POSTPROCESS_LOG="${FINAL_DIR}/postprocess.log"

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

run_cmd "mkdir -p \"${FINAL_DIR}\" \"${FINAL_PLOTS_DIR}\""
run_cmd ": > \"${POSTPROCESS_LOG}\" || true"

# -----------------------------
# Selection helpers
# -----------------------------
config_has_explicit_selected() {
  jq -e '
    (.output.selected // []) as $s
    | ($s | map(tostring) | map(select(. != "default")) | length) > 0
  ' "${CONFIG_PATH}" >/dev/null 2>&1
}

is_selected() {
  local id="$1"

  if config_has_explicit_selected; then
    jq -e --arg id "${id}" '
      (.output.selected // []) as $s
      | ($s | map(tostring)) | index($id) != null
    ' "${CONFIG_PATH}" >/dev/null 2>&1
    return $?
  fi

  # toggle-mode: map id -> output.options path
  # default: if a toggle path is missing, treat as 0 (not selected)
  jq -e --arg id "${id}" '
    def opt(path): (getpath(path) // 0) | (if . == true then 1 elif . == false then 0 else . end);
    def path_for(id):
      if id=="qc.fastqc" then ["output","options","qc","fastqc"]
      elif id=="qc.multiqc" then ["output","options","qc","multiqc"]
      elif id=="qc.qiime2_demux_qzv" then ["output","options","qc","qiime2_demux_qzv"]
      elif id=="tables.feature_table_tsv" then ["output","options","tables","feature_table_tsv"]
      elif id=="tables.feature_table_biom" then ["output","options","tables","feature_table_biom"]
      elif id=="tables.rep_seqs_fasta" then ["output","options","tables","rep_seqs_fasta"]
      elif id=="tables.taxonomy_tsv" then ["output","options","tables","taxonomy_tsv"]
      elif id=="diversity.alpha_tsv" then ["output","options","diversity","alpha_tsv"]
      elif id=="diversity.alpha_plot" then ["output","options","diversity","alpha_plot"]
      elif id=="valencia.output_csv" then ["output","options","valencia","output_csv"]
      elif id=="valencia.plots_svg" then ["output","options","valencia","plots_svg"]
      elif id=="taxa_plots.stacked_bar" then ["output","options","taxa_plots","stacked_bar"]
      elif id=="taxa_plots.heatmap" then ["output","options","taxa_plots","heatmap"]
      elif id=="taxa_plots.pie" then ["output","options","taxa_plots","pie"]
      else null end;
    (path_for($id) as $p
      | if $p == null then 0
        else opt($p)
        end) | tonumber | . == 1
  ' "${CONFIG_PATH}" >/dev/null 2>&1
  return $?
}

# -----------------------------
# Read file paths from outputs.json
# -----------------------------
jq_get() {
  local expr="$1"
  jq -er "${expr} // empty" "${OUTPUTS_JSON}" 2>/dev/null || true
}

MULTIQC_REPORT_HTML="$(jq_get '.multiqc_report_html')"
MULTIQC_DIR="$(jq_get '.multiqc_dir')"

QIIME2_EXPORT_TABLE_TSV="$(jq_get '.qiime2_exports.table_tsv')"
QIIME2_EXPORT_TABLE_BIOM="$(jq_get '.qiime2_exports.table_biom')"
QIIME2_EXPORT_REPSEQS_FASTA="$(jq_get '.qiime2_exports.rep_seqs_fasta')"
QIIME2_EXPORT_TAXONOMY_TSV="$(jq_get '.qiime2_exports.taxonomy_tsv')"

QIIME2_DEMUX_QZV="$(jq_get '.qiime2_artifacts.demux_qzv')"

ALPHA_SHANNON_TSV="$(jq_get '.qiime2_artifacts.alpha_diversity_tsv.shannon')"
ALPHA_OBS_TSV="$(jq_get '.qiime2_artifacts.alpha_diversity_tsv.observed_features')"
ALPHA_PIELOU_TSV="$(jq_get '.qiime2_artifacts.alpha_diversity_tsv.pielou_e')"

VALENCIA_OUTPUT_CSV="$(jq_get '.valencia.output_csv')"
VALENCIA_PLOTS_DIR="$(jq_get '.valencia.plots_dir')"

FASTQC_DIR="${MODULE_DIR}/results/fastqc"

# -----------------------------
# Copy helpers
# -----------------------------
copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -n "${src}" && -e "${src}" ]]; then
    run_cmd "mkdir -p \"$(dirname "${dst}")\""
    run_cmd "cp -R \"${src}\" \"${dst}\""
    echo "COPIED: ${src} -> ${dst}" >> "${POSTPROCESS_LOG}" || true
    return 0
  fi
  echo "MISSING: ${src}" >> "${POSTPROCESS_LOG}" || true
  return 1
}

copy_glob_if_exists() {
  local pattern="$1"
  local dst_dir="$2"
  local any="0"
  shopt -s nullglob
  local files=( $pattern )
  shopt -u nullglob
  if [[ ${#files[@]} -gt 0 ]]; then
    run_cmd "mkdir -p \"${dst_dir}\""
    for f in "${files[@]}"; do
      run_cmd "cp -R \"${f}\" \"${dst_dir}/\""
      any="1"
      echo "COPIED: ${f} -> ${dst_dir}/" >> "${POSTPROCESS_LOG}" || true
    done
  fi
  [[ "${any}" == "1" ]]
}

# -----------------------------
# Copy selected already-generated outputs
# -----------------------------
if is_selected "qc.multiqc"; then
  copy_if_exists "${MULTIQC_REPORT_HTML}" "${FINAL_DIR}/qc/multiqc_report.html" || true
  # optionally copy whole multiqc dir if present
  if [[ -n "${MULTIQC_DIR}" ]]; then
    copy_if_exists "${MULTIQC_DIR}" "${FINAL_DIR}/qc/multiqc" || true
  fi
fi

if is_selected "qc.fastqc"; then
  if [[ -d "${FASTQC_DIR}" ]]; then
    copy_if_exists "${FASTQC_DIR}" "${FINAL_DIR}/qc/fastqc" || true
  else
    echo "MISSING: ${FASTQC_DIR}" >> "${POSTPROCESS_LOG}" || true
  fi
fi

if is_selected "qc.qiime2_demux_qzv"; then
  copy_if_exists "${QIIME2_DEMUX_QZV}" "${FINAL_DIR}/qc/demux.qzv" || true
fi

if is_selected "tables.feature_table_tsv"; then
  copy_if_exists "${QIIME2_EXPORT_TABLE_TSV}" "${FINAL_DIR}/tables/feature-table.tsv" || true
fi
if is_selected "tables.feature_table_biom"; then
  copy_if_exists "${QIIME2_EXPORT_TABLE_BIOM}" "${FINAL_DIR}/tables/feature-table.biom" || true
fi
if is_selected "tables.rep_seqs_fasta"; then
  copy_if_exists "${QIIME2_EXPORT_REPSEQS_FASTA}" "${FINAL_DIR}/tables/rep-seqs.fasta" || true
fi
if is_selected "tables.taxonomy_tsv"; then
  copy_if_exists "${QIIME2_EXPORT_TAXONOMY_TSV}" "${FINAL_DIR}/tables/taxonomy.tsv" || true
fi

if is_selected "diversity.alpha_tsv"; then
  copy_if_exists "${ALPHA_SHANNON_TSV}" "${FINAL_DIR}/diversity/alpha_shannon.tsv" || true
  copy_if_exists "${ALPHA_OBS_TSV}" "${FINAL_DIR}/diversity/alpha_observed_features.tsv" || true
  copy_if_exists "${ALPHA_PIELOU_TSV}" "${FINAL_DIR}/diversity/alpha_pielou_e.tsv" || true
fi

if is_selected "valencia.output_csv"; then
  copy_if_exists "${VALENCIA_OUTPUT_CSV}" "${FINAL_DIR}/valencia/output.csv" || true
fi
if is_selected "valencia.plots_svg"; then
  if [[ -n "${VALENCIA_PLOTS_DIR}" ]]; then
    copy_if_exists "${VALENCIA_PLOTS_DIR}" "${FINAL_DIR}/valencia/plots" || true
  fi
fi

# -----------------------------
# Generate plots (stacked bar / heatmap / pie) from QIIME2 exports
# Requires: feature-table.tsv + taxonomy.tsv
# -----------------------------
NEED_STACKED="false"
NEED_HEATMAP="false"
NEED_PIE="false"
if is_selected "taxa_plots.stacked_bar"; then NEED_STACKED="true"; fi
if is_selected "taxa_plots.heatmap"; then NEED_HEATMAP="true"; fi
if is_selected "taxa_plots.pie"; then NEED_PIE="true"; fi

PLOT_OUT_STACKED_PNG="${FINAL_PLOTS_DIR}/stacked_bar_relative_abundance.png"
PLOT_OUT_STACKED_CSV="${FINAL_PLOTS_DIR}/stacked_bar_relative_abundance_top_taxa.csv"
PLOT_OUT_HEATMAP_PNG="${FINAL_PLOTS_DIR}/heatmap_relative_abundance.png"
PLOT_OUT_HEATMAP_CSV="${FINAL_PLOTS_DIR}/heatmap_relative_abundance_top_taxa.csv"
PLOT_OUT_PIE_PNG="${FINAL_PLOTS_DIR}/pie_overall_relative_abundance.png"
PLOT_OUT_PIE_CSV="${FINAL_PLOTS_DIR}/pie_overall_relative_abundance.csv"

if [[ "${NEED_STACKED}" == "true" || "${NEED_HEATMAP}" == "true" || "${NEED_PIE}" == "true" ]]; then
  if [[ -z "${QIIME2_EXPORT_TABLE_TSV}" || ! -f "${QIIME2_EXPORT_TABLE_TSV}" ]]; then
    echo "WARN: taxa_plots requested but missing feature-table.tsv export at: ${QIIME2_EXPORT_TABLE_TSV}" >&2
    echo "MISSING: ${QIIME2_EXPORT_TABLE_TSV}" >> "${POSTPROCESS_LOG}" || true
  elif [[ -z "${QIIME2_EXPORT_TAXONOMY_TSV}" || ! -f "${QIIME2_EXPORT_TAXONOMY_TSV}" ]]; then
    echo "WARN: taxa_plots requested but missing taxonomy.tsv export at: ${QIIME2_EXPORT_TAXONOMY_TSV}" >&2
    echo "MISSING: ${QIIME2_EXPORT_TAXONOMY_TSV}" >> "${POSTPROCESS_LOG}" || true
  else
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] generate plots using python3 -> ${FINAL_PLOTS_DIR}"
    else
      python3 - \
        "${QIIME2_EXPORT_TABLE_TSV}" \
        "${QIIME2_EXPORT_TAXONOMY_TSV}" \
        "${NEED_STACKED}" "${NEED_HEATMAP}" "${NEED_PIE}" \
        "${PLOT_OUT_STACKED_PNG}" "${PLOT_OUT_STACKED_CSV}" \
        "${PLOT_OUT_HEATMAP_PNG}" "${PLOT_OUT_HEATMAP_CSV}" \
        "${PLOT_OUT_PIE_PNG}" "${PLOT_OUT_PIE_CSV}" \
        >> "${POSTPROCESS_LOG}" 2>&1 <<'PY'
import sys, re, csv, math
from pathlib import Path

table_tsv = Path(sys.argv[1])
tax_tsv = Path(sys.argv[2])

need_stacked = (sys.argv[3].lower() == "true")
need_heatmap = (sys.argv[4].lower() == "true")
need_pie = (sys.argv[5].lower() == "true")

out_stacked_png = Path(sys.argv[6])
out_stacked_csv = Path(sys.argv[7])
out_heatmap_png = Path(sys.argv[8])
out_heatmap_csv = Path(sys.argv[9])
out_pie_png = Path(sys.argv[10])
out_pie_csv = Path(sys.argv[11])

# Lazy import matplotlib only if needed
def ensure_matplotlib():
    import matplotlib  # noqa
    import matplotlib.pyplot as plt  # noqa
    return plt

def parse_qiime_taxon(taxon: str):
    # supports both formats:
    #   k__Bacteria; p__...; ...; g__Lactobacillus; s__crispatus
    #   D_0__Bacteria; D_1__...; ...; D_5__Lactobacillus; D_6__crispatus
    ranks = {"k":"", "p":"", "c":"", "o":"", "f":"", "g":"", "s":""}
    if not taxon or not isinstance(taxon, str):
        return ranks
    parts = [p.strip() for p in taxon.split(";") if p.strip()]
    for p in parts:
        m = re.match(r"^(k|p|c|o|f|g|s)\s*__", p)
        if m:
            key = m.group(1)
            ranks[key] = re.sub(r"^[A-Za-z0-9_]+__+", "", p).strip()
            continue
        m2 = re.match(r"^D_(\d+)__", p)
        if m2:
            idx = int(m2.group(1))
            key = {0:"k",1:"p",2:"c",3:"o",4:"f",5:"g",6:"s"}.get(idx)
            if key:
                ranks[key] = re.sub(r"^D_\d+__+", "", p).strip()
            continue
    return ranks

def pick_label(ranks: dict):
    # prefer species then genus then family...; keep compact and stable for plots
    s = (ranks.get("s") or "").strip()
    g = (ranks.get("g") or "").strip()
    f = (ranks.get("f") or "").strip()
    o = (ranks.get("o") or "").strip()
    c = (ranks.get("c") or "").strip()
    p = (ranks.get("p") or "").strip()
    k = (ranks.get("k") or "").strip()

    if g and s:
        return f"{g} {s}"
    if g:
        return g
    if f:
        return f"f__{f}"
    if o:
        return f"o__{o}"
    if c:
        return f"c__{c}"
    if p:
        return f"p__{p}"
    if k:
        return f"k__{k}"
    return "Unassigned"

# Read taxonomy.tsv (Q2 export)
feature_to_label = {}
with tax_tsv.open("r", encoding="utf-8", errors="replace", newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")
    if not reader.fieldnames or "Feature ID" not in reader.fieldnames or "Taxon" not in reader.fieldnames:
        raise SystemExit("ERROR: taxonomy.tsv missing required columns: Feature ID, Taxon")
    for row in reader:
        fid = (row.get("Feature ID") or "").strip()
        taxon = row.get("Taxon") or ""
        ranks = parse_qiime_taxon(taxon)
        feature_to_label[fid] = pick_label(ranks)

if not feature_to_label:
    raise SystemExit("ERROR: taxonomy.tsv had no rows after parsing")

# Read feature-table.tsv (biom convert output)
lines = table_tsv.read_text(encoding="utf-8", errors="replace").splitlines()
hdr_idx = None
for i, ln in enumerate(lines):
    if ln.startswith("#OTU ID"):
        hdr_idx = i
        break
if hdr_idx is None:
    raise SystemExit("ERROR: feature-table.tsv did not contain '#OTU ID' header (unexpected biom convert output)")

header = lines[hdr_idx].split("\t")
if len(header) < 2:
    raise SystemExit("ERROR: feature-table.tsv header too short")

sample_ids = [h.strip() for h in header[1:] if h.strip()]
if not sample_ids:
    raise SystemExit("ERROR: feature-table.tsv had no sample columns")

# counts_by_sample_label[sample][label] = count
counts_by_sample_label = {s: {} for s in sample_ids}
totals_by_sample = {s: 0 for s in sample_ids}
totals_by_label = {}

for ln in lines[hdr_idx+1:]:
    if not ln.strip():
        continue
    parts = ln.split("\t")
    if len(parts) < 2:
        continue
    fid = parts[0].strip()
    label = feature_to_label.get(fid, "Unassigned")

    for j, s in enumerate(sample_ids, start=1):
        v = 0
        if j < len(parts):
            try:
                v = int(float(parts[j]))
            except Exception:
                v = 0
        if v <= 0:
            continue
        d = counts_by_sample_label[s]
        d[label] = d.get(label, 0) + v
        totals_by_sample[s] += v
        totals_by_label[label] = totals_by_label.get(label, 0) + v

# Build relative abundance table for top taxa
def build_rel_abundance(top_n: int):
    labels_sorted = [t for t, _ in sorted(totals_by_label.items(), key=lambda kv: kv[1], reverse=True)]
    top = labels_sorted[:top_n]
    if len(labels_sorted) > top_n:
        top = top + ["Other"]
    rows = []
    for s in sample_ids:
        total = totals_by_sample.get(s, 0) or 0
        row = {"sample": s}
        other_sum = 0.0
        for lab in labels_sorted:
            c = float(counts_by_sample_label[s].get(lab, 0))
            if total > 0:
                r = c / float(total)
            else:
                r = 0.0
            if lab in top:
                row[lab] = r
            else:
                other_sum += r
        if "Other" in top:
            row["Other"] = other_sum
        rows.append(row)
    return top, rows

def write_csv(path: Path, cols, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["sample", *cols])
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, 0.0) for k in ["sample", *cols]})

# STACKED BAR
if need_stacked:
    top_cols, rows = build_rel_abundance(top_n=15)
    cols_no_other = [c for c in top_cols if c != "Other"]
    write_csv(out_stacked_csv, top_cols, rows)

    plt = ensure_matplotlib()
    import numpy as np

    samples = [r["sample"] for r in rows]
    x = np.arange(len(samples))
    bottom = np.zeros(len(samples), dtype=float)

    fig = plt.figure(figsize=(max(8, len(samples)*0.9), 6))
    ax = fig.add_subplot(111)
    for lab in cols_no_other + (["Other"] if "Other" in top_cols else []):
        vals = np.array([float(r.get(lab, 0.0)) for r in rows], dtype=float)
        ax.bar(x, vals, bottom=bottom, label=lab)
        bottom = bottom + vals

    ax.set_xticks(x)
    ax.set_xticklabels(samples, rotation=45, ha="right")
    ax.set_ylabel("Relative abundance")
    ax.set_title("Relative abundance (top taxa)")
    ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), borderaxespad=0.0, fontsize=8)
    fig.tight_layout()
    out_stacked_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_stacked_png, dpi=200)
    plt.close(fig)

# HEATMAP
if need_heatmap:
    top_cols, rows = build_rel_abundance(top_n=25)
    cols_no_other = [c for c in top_cols if c != "Other"]
    write_csv(out_heatmap_csv, top_cols, rows)

    plt = ensure_matplotlib()
    import numpy as np

    samples = [r["sample"] for r in rows]
    taxa = cols_no_other  # omit Other for heatmap readability
    mat = np.array([[float(r.get(t, 0.0)) for t in taxa] for r in rows], dtype=float)

    fig = plt.figure(figsize=(max(8, len(taxa)*0.35), max(4, len(samples)*0.35)))
    ax = fig.add_subplot(111)
    im = ax.imshow(mat, aspect="auto")

    ax.set_yticks(range(len(samples)))
    ax.set_yticklabels(samples, fontsize=8)
    ax.set_xticks(range(len(taxa)))
    ax.set_xticklabels(taxa, rotation=45, ha="right", fontsize=8)
    ax.set_title("Heatmap: relative abundance (top taxa)")
    fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    fig.tight_layout()
    out_heatmap_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_heatmap_png, dpi=200)
    plt.close(fig)

# PIE (overall)
if need_pie:
    # overall relative abundance across all samples (by total counts)
    total_all = float(sum(totals_by_label.values()) or 0.0)
    items = sorted(totals_by_label.items(), key=lambda kv: kv[1], reverse=True)

    top_n = 12
    top_items = items[:top_n]
    other_sum = sum(v for _, v in items[top_n:])

    labels = [k for k, _ in top_items]
    values = [float(v) for _, v in top_items]
    if other_sum > 0:
        labels.append("Other")
        values.append(float(other_sum))

    # write csv
    out_pie_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_pie_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["taxon", "count", "relative_abundance"])
        for lab, v in zip(labels, values):
            ra = (v / total_all) if total_all > 0 else 0.0
            w.writerow([lab, int(v), ra])

    plt = ensure_matplotlib()
    fig = plt.figure(figsize=(7, 7))
    ax = fig.add_subplot(111)
    ax.pie(values, labels=labels, autopct=lambda p: f"{p:.1f}%" if p >= 2 else "")
    ax.set_title("Overall relative abundance (top taxa)")
    fig.tight_layout()
    out_pie_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_pie_png, dpi=200)
    plt.close(fig)

print("OK: taxa plots generated")
PY
    fi
  fi
fi

# If we generated plots, copy into final (already written there). Nothing else required.

# -----------------------------
# Write final manifest.json
# -----------------------------
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[dry-run] write manifest: ${MANIFEST_JSON}"
else
  python3 - \
    "${CONFIG_PATH}" \
    "${OUTPUTS_JSON}" \
    "${FINAL_DIR}" \
    "${MANIFEST_JSON}" \
    "${PLOT_OUT_STACKED_PNG}" "${PLOT_OUT_STACKED_CSV}" \
    "${PLOT_OUT_HEATMAP_PNG}" "${PLOT_OUT_HEATMAP_CSV}" \
    "${PLOT_OUT_PIE_PNG}" "${PLOT_OUT_PIE_CSV" \
    "${FINAL_DIR}/qc/multiqc_report.html" \
    "${FINAL_DIR}/qc/demux.qzv" \
    "${FINAL_DIR}/qc/fastqc" \
    "${FINAL_DIR}/qc/multiqc" \
    "${FINAL_DIR}/tables/feature-table.tsv" \
    "${FINAL_DIR}/tables/feature-table.biom" \
    "${FINAL_DIR}/tables/rep-seqs.fasta" \
    "${FINAL_DIR}/tables/taxonomy.tsv" \
    "${FINAL_DIR}/diversity/alpha_shannon.tsv" \
    "${FINAL_DIR}/diversity/alpha_observed_features.tsv" \
    "${FINAL_DIR}/diversity/alpha_pielou_e.tsv" \
    "${FINAL_DIR}/valencia/output.csv" \
    "${FINAL_DIR}/valencia/plots" \
    >> "${POSTPROCESS_LOG}" 2>&1 <<'PY'
import json, sys, os
from pathlib import Path

cfg_path = Path(sys.argv[1])
sr_outputs_json = Path(sys.argv[2])
final_dir = Path(sys.argv[3])
manifest_path = Path(sys.argv[4])

# generated plot + copied candidates (paths may not exist)
paths = {
  "taxa_plots.stacked_bar.png": Path(sys.argv[5]),
  "taxa_plots.stacked_bar.csv": Path(sys.argv[6]),
  "taxa_plots.heatmap.png": Path(sys.argv[7]),
  "taxa_plots.heatmap.csv": Path(sys.argv[8]),
  "taxa_plots.pie.png": Path(sys.argv[9]),
  "taxa_plots.pie.csv": Path(sys.argv[10]),

  "qc.multiqc_report.html": Path(sys.argv[11]),
  "qc.qiime2_demux.qzv": Path(sys.argv[12]),
  "qc.fastqc.dir": Path(sys.argv[13]),
  "qc.multiqc.dir": Path(sys.argv[14]),

  "tables.feature_table.tsv": Path(sys.argv[15]),
  "tables.feature_table.biom": Path(sys.argv[16]),
  "tables.rep_seqs.fasta": Path(sys.argv[17]),
  "tables.taxonomy.tsv": Path(sys.argv[18]),

  "diversity.alpha_shannon.tsv": Path(sys.argv[19]),
  "diversity.alpha_observed_features.tsv": Path(sys.argv[20]),
  "diversity.alpha_pielou_e.tsv": Path(sys.argv[21]),

  "valencia.output.csv": Path(sys.argv[22]),
  "valencia.plots.dir": Path(sys.argv[23]),
}

def read_json(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}

cfg = read_json(cfg_path)
sr = read_json(sr_outputs_json)

def has_explicit_selected(cfg):
    sel = (cfg.get("output", {}) or {}).get("selected", []) or []
    sel = [str(x) for x in sel]
    return any(x != "default" for x in sel)

def is_selected(cfg, id_):
    if has_explicit_selected(cfg):
        sel = (cfg.get("output", {}) or {}).get("selected", []) or []
        sel = [str(x) for x in sel]
        return (id_ in sel)
    # toggle mode
    opt = (cfg.get("output", {}) or {}).get("options", {}) or {}
    def get_flag(path, default=0):
        cur = opt
        for k in path:
            if not isinstance(cur, dict) or k not in cur:
                return default
            cur = cur[k]
        if cur is True: return 1
        if cur is False: return 0
        try:
            return int(cur)
        except Exception:
            return default

    mapping = {
      "qc.fastqc": ["qc", "fastqc"],
      "qc.multiqc": ["qc", "multiqc"],
      "qc.qiime2_demux_qzv": ["qc", "qiime2_demux_qzv"],

      "tables.feature_table_tsv": ["tables", "feature_table_tsv"],
      "tables.feature_table_biom": ["tables", "feature_table_biom"],
      "tables.rep_seqs_fasta": ["tables", "rep_seqs_fasta"],
      "tables.taxonomy_tsv": ["tables", "taxonomy_tsv"],

      "diversity.alpha_tsv": ["diversity", "alpha_tsv"],
      "diversity.alpha_plot": ["diversity", "alpha_plot"],

      "valencia.output_csv": ["valencia", "output_csv"],
      "valencia.plots_svg": ["valencia", "plots_svg"],

      "taxa_plots.stacked_bar": ["taxa_plots", "stacked_bar"],
      "taxa_plots.heatmap": ["taxa_plots", "heatmap"],
      "taxa_plots.pie": ["taxa_plots", "pie"],
    }
    if id_ not in mapping:
        return False
    return get_flag(mapping[id_], 0) == 1

items = []

def add_item(id_, label, path: Path, kind=None, mime=None):
    if not path.exists():
        return
    rel = os.path.relpath(str(path), start=str(final_dir))
    items.append({
      "id": id_,
      "label": label,
      "path": rel.replace("\\", "/"),
      "kind": kind,
      "mime": mime,
      "bytes": path.stat().st_size if path.is_file() else None,
    })

# QC
if is_selected(cfg, "qc.multiqc"):
    add_item("qc.multiqc_report", "MultiQC report", paths["qc.multiqc_report.html"], kind="report", mime="text/html")
    if paths["qc.multiqc.dir"].exists():
        add_item("qc.multiqc_dir", "MultiQC folder", paths["qc.multiqc.dir"], kind="dir", mime=None)

if is_selected(cfg, "qc.fastqc"):
    if paths["qc.fastqc.dir"].exists():
        add_item("qc.fastqc_dir", "FastQC folder", paths["qc.fastqc.dir"], kind="dir", mime=None)

if is_selected(cfg, "qc.qiime2_demux_qzv"):
    add_item("qc.demux_qzv", "QIIME2 demux summary (qzv)", paths["qc.qiime2_demux.qzv"], kind="qiime2", mime="application/zip")

# Tables
if is_selected(cfg, "tables.feature_table_tsv"):
    add_item("tables.feature_table_tsv", "Feature table (TSV)", paths["tables.feature_table.tsv"], kind="table", mime="text/tab-separated-values")
if is_selected(cfg, "tables.feature_table_biom"):
    add_item("tables.feature_table_biom", "Feature table (BIOM)", paths["tables.feature_table.biom"], kind="table", mime="application/octet-stream")
if is_selected(cfg, "tables.rep_seqs_fasta"):
    add_item("tables.rep_seqs_fasta", "Representative sequences (FASTA)", paths["tables.rep_seqs.fasta"], kind="fasta", mime="text/plain")
if is_selected(cfg, "tables.taxonomy_tsv"):
    add_item("tables.taxonomy_tsv", "Taxonomy (TSV)", paths["tables.taxonomy.tsv"], kind="table", mime="text/tab-separated-values")

# Diversity
if is_selected(cfg, "diversity.alpha_tsv"):
    add_item("diversity.alpha_shannon", "Alpha diversity (Shannon)", paths["diversity.alpha_shannon.tsv"], kind="table", mime="text/tab-separated-values")
    add_item("diversity.alpha_observed_features", "Alpha diversity (Observed features)", paths["diversity.alpha_observed_features.tsv"], kind="table", mime="text/tab-separated-values")
    add_item("diversity.alpha_pielou_e", "Alpha diversity (Pielou's evenness)", paths["diversity.alpha_pielou_e.tsv"], kind="table", mime="text/tab-separated-values")

# Valencia
if is_selected(cfg, "valencia.output_csv"):
    add_item("valencia.output_csv", "VALENCIA output (CSV)", paths["valencia.output.csv"], kind="table", mime="text/csv")
if is_selected(cfg, "valencia.plots_svg"):
    if paths["valencia.plots.dir"].exists():
        add_item("valencia.plots_dir", "VALENCIA plots (SVG)", paths["valencia.plots.dir"], kind="dir", mime=None)

# Taxa plots (generated)
if is_selected(cfg, "taxa_plots.stacked_bar"):
    add_item("taxa_plots.stacked_bar_png", "Stacked bar (relative abundance)", paths["taxa_plots.stacked_bar.png"], kind="plot", mime="image/png")
    add_item("taxa_plots.stacked_bar_csv", "Stacked bar data (CSV)", paths["taxa_plots.stacked_bar.csv"], kind="table", mime="text/csv")

if is_selected(cfg, "taxa_plots.heatmap"):
    add_item("taxa_plots.heatmap_png", "Heatmap (relative abundance)", paths["taxa_plots.heatmap.png"], kind="plot", mime="image/png")
    add_item("taxa_plots.heatmap_csv", "Heatmap data (CSV)", paths["taxa_plots.heatmap.csv"], kind="table", mime="text/csv")

if is_selected(cfg, "taxa_plots.pie"):
    add_item("taxa_plots.pie_png", "Pie chart (overall relative abundance)", paths["taxa_plots.pie.png"], kind="plot", mime="image/png")
    add_item("taxa_plots.pie_csv", "Pie chart data (CSV)", paths["taxa_plots.pie.csv"], kind="table", mime="text/csv")

manifest = {
  "module": "sr_amp",
  "final_dir": str(final_dir),
  "source_outputs_json": str(sr_outputs_json),
  "selected_mode": "explicit_selected" if has_explicit_selected(cfg) else "options_flags",
  "items": items,
  "notes": [
    "Paths are relative to sr_amp/final/",
    "taxa_plots require QIIME2 exports: feature-table.tsv + taxonomy.tsv"
  ]
}

manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
print(f"OK: wrote manifest -> {manifest_path}")
PY
fi

echo "Postprocess (single) complete."
echo "  Final dir:  ${FINAL_DIR}"
echo "  Manifest:   ${MANIFEST_JSON}"
echo "  Log:        ${POSTPROCESS_LOG}"
