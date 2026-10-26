#!/usr/bin/env bash
set -euo pipefail

MODULE_NAME="sr_amp"

usage() { echo "Usage: $0 --config <config.json>"; }

CONFIG_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${CONFIG_PATH}" ]]; then echo "ERROR: --config is required" >&2; usage; exit 2; fi
if [[ ! -f "${CONFIG_PATH}" ]]; then echo "ERROR: Config not found: ${CONFIG_PATH}" >&2; exit 2; fi
if ! command -v jq >/dev/null 2>&1; then echo "ERROR: jq is required but not found in PATH" >&2; exit 2; fi
if ! command -v python3 >/dev/null 2>&1; then echo "ERROR: python3 is required but not found in PATH" >&2; exit 2; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_SH="${PIPELINES_DIR}/tools.sh"
if [[ ! -f "${TOOLS_SH}" ]]; then echo "ERROR: Missing shared tools file: ${TOOLS_SH}" >&2; exit 2; fi
# shellcheck disable=SC1090
source "${TOOLS_SH}"

jq_first() {
  local file="$1"; shift
  local v=""
  for expr in "$@"; do
    v="$(jq -er "${expr} // empty" "${file}" 2>/dev/null || true)"
    if [[ -n "${v}" && "${v}" != "null" ]]; then
      echo "${v}"
      return 0
    fi
  done
  return 1
}

jq_first_int() {
  local file="$1"; shift
  local v=""
  for expr in "$@"; do
    v="$(jq -er "${expr} // empty" "${file}" 2>/dev/null || true)"
    if [[ -n "${v}" && "${v}" != "null" && "${v}" =~ ^-?[0-9]+$ ]]; then
      echo "${v}"
      return 0
    fi
  done
  return 1
}

require_file() {
  local p="$1"
  [[ -n "${p}" && "${p}" != "null" ]] || { echo "ERROR: Required file path is empty" >&2; exit 2; }
  [[ -f "${p}" ]] || { echo "ERROR: File not found: ${p}" >&2; exit 2; }
}

count_fastq_lines() {
  local p="$1"
  if [[ -z "${p}" || "${p}" == "null" ]]; then
    echo "0"
    return 0
  fi
  require_file "${p}"
  if [[ "${p}" == *.gz ]]; then
    (gzip -cd "${p}" | wc -l 2>/dev/null || true) | tr -cd '0-9'
  else
    (wc -l < "${p}" 2>/dev/null || true) | tr -cd '0-9'
  fi
}

estimate_reads_from_lines() {
  local lines="$1"
  python3 - "$lines" <<'PY'
import sys
s = sys.argv[1]
s = "".join([c for c in s if c.isdigit()]) or "0"
lines = int(s)
print(lines // 4)
PY
}

iso_now() {
  python3 - <<'PY'
from datetime import datetime, timezone, timedelta
tz = timezone(timedelta(hours=10))
print(datetime.now(tz).isoformat(timespec="seconds"))
PY
}

steps_init_if_needed() { local p="$1"; [[ -f "${p}" ]] || printf "[]\n" > "${p}"; }

steps_append() {
  local steps_path="$1" step_name="$2" status="$3" message="$4" tool="$5" cmd="$6" exit_code="$7" started_at="$8" ended_at="$9"
  steps_init_if_needed "${steps_path}"
  python3 - "${steps_path}" "${step_name}" "${status}" "${message}" "${tool}" "${cmd}" "${exit_code}" "${started_at}" "${ended_at}" <<'PY'
import json, sys
path, step_name, status, message, tool, cmd, exit_code, started_at, ended_at = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    arr = json.load(f)
arr.append({
    "step": step_name,
    "status": status,
    "message": message,
    "tool": tool or None,
    "command": cmd or None,
    "exit_code": int(exit_code) if exit_code not in ("", "null") else None,
    "started_at": started_at,
    "ended_at": ended_at,
})
with open(path, "w", encoding="utf-8") as f:
    json.dump(arr, f, ensure_ascii=False, indent=2)
PY
}

print_step_status() {
  local steps_path="$1"
  local step="$2"
  if [[ ! -f "${steps_path}" ]]; then
    echo "[${MODULE_NAME}] ${step}: no steps.json"
    return 0
  fi
  python3 - "${steps_path}" "${step}" "${MODULE_NAME}" <<'PY'
import json, sys
path, step, module = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    arr = json.load(f)
found = [x for x in arr if x.get("step")==step]
if not found:
    print(f"[{module}] {step}: not recorded")
    raise SystemExit(0)
x = found[-1]
status = x.get("status","")
msg = x.get("message","")
print(f"[{module}] {step}: {status} - {msg}")
PY
}

fail_if_missing_files() {
  local missing=0
  for p in "$@"; do
    if [[ -z "${p}" || "${p}" == "null" ]]; then
      continue
    fi
    if [[ ! -f "${p}" ]]; then
      echo "ERROR: Expected file missing: ${p}" >&2
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || return 1
}

derive_canonical_barcode_id() {
  local a="${1:-}"
  local b="${2:-}"
  python3 - "$a" "$b" <<'PY'
import re, sys

a = sys.argv[1] or ""
b = sys.argv[2] or ""

bc_re = re.compile(r'(barcode|bc)[\s_\-]*0*([0-9]{1,3})', re.IGNORECASE)

def find_id(s: str):
    m = bc_re.search(s or "")
    if not m:
        return None
    n = int(m.group(2))
    return f"barcode{n:02d}"

sid = find_id(a) or find_id(b)
print(sid or "")
PY
}

# -----------------------------
# Validate input style / config
# -----------------------------
INPUT_STYLE="$(jq_first "${CONFIG_PATH}" '.input.style' '.inputs.style' '.input_style' '.inputs.input_style' || true)"
[[ -n "${INPUT_STYLE}" ]] || INPUT_STYLE="FASTQ_PAIRED"

if [[ "${INPUT_STYLE}" != "FASTQ_PAIRED" && "${INPUT_STYLE}" != "FASTQ_SINGLE" ]]; then
  echo "ERROR: ${MODULE_NAME} expects FASTQ_PAIRED or FASTQ_SINGLE, got: ${INPUT_STYLE}" >&2
  exit 2
fi

OUTPUT_DIR="$(jq_first "${CONFIG_PATH}" \
  '.run_dir' \
  '.run.run_dir' \
  '.run.work_dir' \
  '.output_dir' \
  '.run.output_dir' \
  '.outputs.output_dir' \
  '.output.output_dir' \
  || true)"
[[ -n "${OUTPUT_DIR}" ]] || { echo "ERROR: Could not determine output dir from config" >&2; exit 2; }
mkdir -p "${OUTPUT_DIR}"

RUN_ID="$(jq_first "${CONFIG_PATH}" '.run_id_resolved' '.run.run_id' '.run_id' '.id' '.run.id' || true)"
PIPELINE_ID="$(jq_first "${CONFIG_PATH}" '.pipeline_id' '.run.pipeline_id' '.pipeline.id' '.pipeline_key' || true)"

SAMPLE_ID="$(jq_first "${CONFIG_PATH}" '.qiime2.sample_id' '.sample_id' || true)"
[[ -n "${SAMPLE_ID}" ]] || SAMPLE_ID="barcode01"
if [[ "${SAMPLE_ID}" == "sample1" ]]; then SAMPLE_ID="barcode01"; fi

FASTQ_R1_SRC="$(jq_first "${CONFIG_PATH}" '.input.fastq_r1' '.inputs.fastq_r1' '.input.r1' '.inputs.r1' '.input.read1' '.inputs.read1' || true)"
FASTQ_R2_SRC="$(jq_first "${CONFIG_PATH}" '.input.fastq_r2' '.inputs.fastq_r2' '.input.r2' '.inputs.r2' '.input.read2' '.inputs.read2' || true)"

if [[ -z "${FASTQ_R1_SRC}" ]]; then
  echo "ERROR: ${INPUT_STYLE} requires input.fastq_r1 in config." >&2
  exit 2
fi
require_file "${FASTQ_R1_SRC}"

if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
  [[ -n "${FASTQ_R2_SRC}" ]] || { echo "ERROR: FASTQ_PAIRED requires input.fastq_r2 in config." >&2; exit 2; }
  require_file "${FASTQ_R2_SRC}"
else
  FASTQ_R2_SRC=""
fi

PRIMER_FWD="$(jq_first "${CONFIG_PATH}" '.qiime2.primers.forward' || true)"
PRIMER_REV="$(jq_first "${CONFIG_PATH}" '.qiime2.primers.reverse' || true)"
CLASSIFIER_QZA_HOST="$(jq_first "${CONFIG_PATH}" '.qiime2.classifier.qza' || true)"
META_TSV_HOST="$(jq_first "${CONFIG_PATH}" '.qiime2.diversity.metadata_tsv' '.qiime2.metadata_tsv' || true)"
SAMPLING_DEPTH="$(jq_first_int "${CONFIG_PATH}" '.qiime2.diversity.sampling_depth' || true)"

DADA2_TRIM_LEFT_F="$(jq_first_int "${CONFIG_PATH}" '.qiime2.dada2.trim_left_f' || true)"
DADA2_TRIM_LEFT_R="$(jq_first_int "${CONFIG_PATH}" '.qiime2.dada2.trim_left_r' || true)"
DADA2_TRUNC_LEN_F="$(jq_first_int "${CONFIG_PATH}" '.qiime2.dada2.trunc_len_f' || true)"
DADA2_TRUNC_LEN_R="$(jq_first_int "${CONFIG_PATH}" '.qiime2.dada2.trunc_len_r' || true)"
DADA2_N_THREADS="$(jq_first_int "${CONFIG_PATH}" '.qiime2.dada2.n_threads' || true)"

# -----------------------------
# Layout: <run_dir>/sr_amp/...
# -----------------------------
MODULE_OUT_DIR="${OUTPUT_DIR}/${MODULE_NAME}"
FASTQ_STAGE_DIR="${MODULE_OUT_DIR}/inputs/fastq"
REF_STAGE_DIR="${MODULE_OUT_DIR}/inputs/reference"
META_STAGE_DIR="${MODULE_OUT_DIR}/inputs/metadata"
RESULTS_DIR="${MODULE_OUT_DIR}/results"
LOGS_DIR="${MODULE_OUT_DIR}/logs"
STEPS_JSON="${MODULE_OUT_DIR}/steps.json"
mkdir -p "${FASTQ_STAGE_DIR}" "${REF_STAGE_DIR}" "${META_STAGE_DIR}" "${RESULTS_DIR}" "${LOGS_DIR}"

# Reset steps.json at the start of each run (prevent accumulation from previous runs)
printf "[]\n" > "${STEPS_JSON}"

STAGED_R1="${FASTQ_STAGE_DIR}/$(basename "${FASTQ_R1_SRC}")"
STAGED_R2=""
rm -f "${STAGED_R1}"
cp -f "${FASTQ_R1_SRC}" "${STAGED_R1}"

if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
  STAGED_R2="${FASTQ_STAGE_DIR}/$(basename "${FASTQ_R2_SRC}")"
  rm -f "${STAGED_R2}"
  cp -f "${FASTQ_R2_SRC}" "${STAGED_R2}"
fi

DERIVED_BC_ID="$(derive_canonical_barcode_id "${STAGED_R1}" "${STAGED_R2}")"
if [[ -z "${DERIVED_BC_ID}" ]]; then
  FALLBACK_ID="$(python3 - "$(basename "${STAGED_R1}")" <<'PY'
import re, sys
name = sys.argv[1]
name = re.sub(r'\.f(ast)?q(\.gz)?$', '', name, flags=re.IGNORECASE)
name = re.sub(r'(_R?1|_1)$', '', name)
print(name)
PY
)"
  if [[ -n "${FALLBACK_ID}" ]]; then
    SAMPLE_ID="${FALLBACK_ID}"
  fi
fi

STAGED_CLASSIFIER=""
if [[ -n "${CLASSIFIER_QZA_HOST}" ]]; then
  CLASSIFIER_QZA_HOST="$(printf "%s" "${CLASSIFIER_QZA_HOST}" | tr -d '\r\n')"
  require_file "${CLASSIFIER_QZA_HOST}"
  STAGED_CLASSIFIER="${REF_STAGE_DIR}/$(basename "${CLASSIFIER_QZA_HOST}")"
  rm -f "${STAGED_CLASSIFIER}"
  cp -f "${CLASSIFIER_QZA_HOST}" "${STAGED_CLASSIFIER}"
fi

STAGED_META=""
if [[ -n "${META_TSV_HOST}" ]]; then
  META_TSV_HOST="$(printf "%s" "${META_TSV_HOST}" | tr -d '\r\n')"
  require_file "${META_TSV_HOST}"
  STAGED_META="${META_STAGE_DIR}/$(basename "${META_TSV_HOST}")"
  rm -f "${STAGED_META}"
  cp -f "${META_TSV_HOST}" "${STAGED_META}"
fi

STAGED_META_NORMALIZED=""
META_NORMALIZE_LOG="${LOGS_DIR}/metadata_normalize.log"
if [[ -n "${STAGED_META}" ]]; then
  STAGED_META_NORMALIZED="${META_STAGE_DIR}/metadata.normalized.tsv"
  started="$(iso_now)"
  set +e
  python3 - "${STAGED_META}" "${STAGED_META_NORMALIZED}" "${SAMPLE_ID}" >"${META_NORMALIZE_LOG}" 2>&1 <<'PY'
import sys, re

src, dst, want_id = sys.argv[1:]
want_id = (want_id or "").strip()

bc_re = re.compile(r'(barcode|bc)[\s_\-]*0*([0-9]{1,3})', re.IGNORECASE)

def canon_id(s: str) -> str:
    s = (s or "").strip()
    m = bc_re.search(s)
    if not m:
        return s
    n = int(m.group(2))
    return f"barcode{n:02d}"

lines = []
with open(src, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

if not lines:
    raise SystemExit("ERROR: metadata file is empty")

preamble = []
idx = 0
while idx < len(lines) and lines[idx].startswith("#"):
    preamble.append(lines[idx])
    idx += 1

if idx >= len(lines):
    raise SystemExit("ERROR: metadata file has no header row")

header = lines[idx]
idx += 1

delim = "\t" if "\t" in header else ","
hdr = header.split(delim)

sid_col = None
for i, c in enumerate(hdr):
    if c.strip().lower() == "sample-id":
        sid_col = i
        break
if sid_col is None:
    sid_col = 0
    hdr[0] = "sample-id"

rows = []
seen = set()

for j in range(idx, len(lines)):
    ln = lines[j]
    if not ln.strip() or ln.lstrip().startswith("#"):
        continue
    parts = ln.split(delim)
    if len(parts) < len(hdr):
        parts = parts + [""] * (len(hdr) - len(parts))
    old = parts[sid_col].strip()
    new = canon_id(old)
    parts[sid_col] = new
    rows.append(parts)
    seen.add(new)

want_canon = canon_id(want_id)
if want_canon and want_canon not in seen:
    blank = [""] * len(hdr)
    blank[sid_col] = want_canon
    rows.append(blank)

with open(dst, "w", encoding="utf-8", newline="") as out:
    for ln in preamble:
        out.write(ln + "\n")
    out.write(delim.join(hdr) + "\n")
    for r in rows:
        out.write(delim.join(r) + "\n")

print(f"OK: normalized metadata IDs -> {dst}")
print(f"OK: ensured sample-id present -> {want_canon}")
PY
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "metadata_normalize" "succeeded" "Normalized metadata sample IDs to barcodeXX (see logs/metadata_normalize.log)" "python3" "python3 normalize_metadata" "0" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "metadata_normalize" "failed" "Metadata normalization failed (see logs/metadata_normalize.log)" "python3" "python3 normalize_metadata" "${ec}" "${started}" "${ended}"
    echo "ERROR: Failed to normalize metadata for QIIME2. See: ${META_NORMALIZE_LOG}" >&2
    exit 2
  fi
fi

# -----------------------------
# outputs.json base
# -----------------------------
OUTPUTS_JSON="${MODULE_OUT_DIR}/outputs.json"
jq -n \
  --arg mod "${MODULE_NAME}" \
  --arg pipeline_id "${PIPELINE_ID:-}" \
  --arg run_id "${RUN_ID:-}" \
  --arg sample_id "${SAMPLE_ID}" \
  --arg input_style "${INPUT_STYLE}" \
  --arg fastq_r1 "${STAGED_R1}" \
  --arg fastq_r2 "${STAGED_R2}" \
  --arg classifier_qza "${STAGED_CLASSIFIER}" \
  --arg metadata_tsv "${STAGED_META}" \
  --arg metadata_tsv_normalized "${STAGED_META_NORMALIZED}" \
  '{
    module_name: $mod,
    pipeline_id: $pipeline_id,
    run_id: $run_id,
    sample_id: $sample_id,
    input_style: $input_style,
    inputs: {
      fastq_r1: $fastq_r1,
      fastq_r2: ($fastq_r2 | select(length>0) // null)
    },
    reference: { classifier_qza: ($classifier_qza | select(length>0) // null) },
    metadata: {
      metadata_tsv: ($metadata_tsv | select(length>0) // null),
      metadata_tsv_normalized: ($metadata_tsv_normalized | select(length>0) // null)
    }
  }' > "${OUTPUTS_JSON}"

# -----------------------------
# Metrics
# -----------------------------
METRICS_JSON="${MODULE_OUT_DIR}/metrics.json"
R1_LINES="$(count_fastq_lines "${STAGED_R1}")"
R2_LINES="$(count_fastq_lines "${STAGED_R2}")"
[[ -n "${R1_LINES}" ]] || R1_LINES="0"
[[ -n "${R2_LINES}" ]] || R2_LINES="0"
R1_READS="$(estimate_reads_from_lines "${R1_LINES}")"
R2_READS="$(estimate_reads_from_lines "${R2_LINES}")"

jq -n \
  --arg mod "${MODULE_NAME}" \
  --arg fastq_r1 "${STAGED_R1}" \
  --arg fastq_r2 "${STAGED_R2}" \
  --argjson r1_lines "${R1_LINES}" \
  --argjson r2_lines "${R2_LINES}" \
  --argjson r1_reads_estimate "${R1_READS}" \
  --argjson r2_reads_estimate "${R2_READS}" \
  '{
    module_name: $mod,
    fastq_r1: $fastq_r1,
    fastq_r2: ($fastq_r2 | select(length>0) // null),
    r1_lines: $r1_lines,
    r2_lines: $r2_lines,
    r1_reads_estimate: $r1_reads_estimate,
    r2_reads_estimate: $r2_reads_estimate
  }' > "${METRICS_JSON}"

tmp="${OUTPUTS_JSON}.tmp"
jq --arg metrics_path "${METRICS_JSON}" --slurpfile metrics "${METRICS_JSON}" '. + {metrics_path:$metrics_path, metrics:$metrics[0]}' "${OUTPUTS_JSON}" > "${tmp}"
mv "${tmp}" "${OUTPUTS_JSON}"

# -----------------------------
# FastQC + MultiQC (optional)
# -----------------------------
FASTQC_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.fastqc_bin' 'fastqc')"
FASTQC_OUTDIR="${RESULTS_DIR}/fastqc"
FASTQC_LOG="${LOGS_DIR}/fastqc.log"

if [[ -z "${FASTQC_BIN}" ]]; then
  started="$(iso_now)"; ended="$(iso_now)"
  steps_append "${STEPS_JSON}" "fastqc" "skipped" "fastqc not found (install fastqc or set tools.fastqc_bin)" "" "" "0" "${started}" "${ended}"
else
  mkdir -p "${FASTQC_OUTDIR}"
  started="$(iso_now)"
  set +e
  if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
    "${FASTQC_BIN}" -o "${FASTQC_OUTDIR}" "${STAGED_R1}" "${STAGED_R2}" >"${FASTQC_LOG}" 2>&1
  else
    "${FASTQC_BIN}" -o "${FASTQC_OUTDIR}" "${STAGED_R1}" >"${FASTQC_LOG}" 2>&1
  fi
  ec=$?
  set -e
  ended="$(iso_now)"

  if exit_code_means_tool_missing "${ec}"; then
    steps_append "${STEPS_JSON}" "fastqc" "skipped" "fastqc command not found at runtime (check tools.fastqc_bin / PATH)" "${FASTQC_BIN}" "fastqc" "${ec}" "${started}" "${ended}"
  elif [[ $ec -eq 0 ]]; then
    if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
      steps_append "${STEPS_JSON}" "fastqc" "succeeded" "fastqc completed (R1 + R2)" "${FASTQC_BIN}" "fastqc" "${ec}" "${started}" "${ended}"
    else
      steps_append "${STEPS_JSON}" "fastqc" "succeeded" "fastqc completed (R1 only; single-end)" "${FASTQC_BIN}" "fastqc" "${ec}" "${started}" "${ended}"
    fi
  else
    steps_append "${STEPS_JSON}" "fastqc" "failed" "fastqc failed (see logs/fastqc.log)" "${FASTQC_BIN}" "fastqc" "${ec}" "${started}" "${ended}"
  fi
fi

MULTIQC_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.multiqc_bin' 'multiqc')"
MULTIQC_LOG="${LOGS_DIR}/multiqc.log"
MULTIQC_OUTDIR="${RESULTS_DIR}/multiqc"

if [[ -z "${MULTIQC_BIN}" ]]; then
  started="$(iso_now)"; ended="$(iso_now)"
  steps_append "${STEPS_JSON}" "multiqc" "skipped" "multiqc not found (install multiqc or set tools.multiqc_bin)" "" "" "0" "${started}" "${ended}"
else
  mkdir -p "${MULTIQC_OUTDIR}"
  started="$(iso_now)"
  set +e
  "${MULTIQC_BIN}" -o "${MULTIQC_OUTDIR}" "${RESULTS_DIR}" >"${MULTIQC_LOG}" 2>&1
  ec=$?
  set -e
  ended="$(iso_now)"

  if exit_code_means_tool_missing "${ec}"; then
    steps_append "${STEPS_JSON}" "multiqc" "skipped" "multiqc command not found at runtime (check tools.multiqc_bin / PATH)" "${MULTIQC_BIN}" "multiqc" "${ec}" "${started}" "${ended}"
  elif [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "multiqc" "succeeded" "multiqc completed" "${MULTIQC_BIN}" "multiqc" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "multiqc" "failed" "multiqc failed (see logs/multiqc.log)" "${MULTIQC_BIN}" "multiqc" "${ec}" "${started}" "${ended}"
  fi
fi

MULTIQC_REPORT="${MULTIQC_OUTDIR}/multiqc_report.html"
tmp="${OUTPUTS_JSON}.tmp"
jq --arg steps_path "${STEPS_JSON}" \
   --arg multiqc_dir "${MULTIQC_OUTDIR}" \
   --arg multiqc_report_html "${MULTIQC_REPORT}" \
   '. + {steps_path:$steps_path, multiqc_dir:$multiqc_dir, multiqc_report_html:$multiqc_report_html}' "${OUTPUTS_JSON}" > "${tmp}"
mv "${tmp}" "${OUTPUTS_JSON}"

# -----------------------------
# QIIME2 (inner docker)
# -----------------------------
QIIME2_IMAGE="quay.io/qiime2/amplicon:2024.10"
QIIME2_DIR="${RESULTS_DIR}/qiime2"
QIIME2_LOG="${LOGS_DIR}/qiime2.log"
mkdir -p "${QIIME2_DIR}"

QIIME2_MANIFEST_TSV="${QIIME2_DIR}/manifest.tsv"

if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
  QIIME2_DEMUX_QZA="${QIIME2_DIR}/demux-paired-end.qza"
  QIIME2_DEMUX_QZV="${QIIME2_DIR}/demux-paired-end.qzv"
else
  QIIME2_DEMUX_QZA="${QIIME2_DIR}/demux-single-end.qza"
  QIIME2_DEMUX_QZV="${QIIME2_DIR}/demux-single-end.qzv"
fi

QIIME2_TRIMMED_QZA="${QIIME2_DIR}/trimmed.qza"
QIIME2_TRIMMED_QZV="${QIIME2_DIR}/trimmed.qzv"

QIIME2_TABLE_QZA="${QIIME2_DIR}/table.qza"
QIIME2_REPSEQ_QZA="${QIIME2_DIR}/rep-seqs.qza"
QIIME2_DADA2_STATS_QZA="${QIIME2_DIR}/denoising-stats.qza"
QIIME2_TABLE_QZV="${QIIME2_DIR}/table.qzv"
QIIME2_REPSEQ_QZV="${QIIME2_DIR}/rep-seqs.qzv"
QIIME2_DADA2_STATS_QZV="${QIIME2_DIR}/denoising-stats.qzv"

QIIME2_TAXONOMY_QZA="${QIIME2_DIR}/taxonomy.qza"
QIIME2_TAXONOMY_QZV="${QIIME2_DIR}/taxonomy.qzv"
QIIME2_TAXA_BARPLOT_QZV="${QIIME2_DIR}/taxa-barplot.qzv"

QIIME2_PHYLOGENY_DIR="${QIIME2_DIR}/phylogeny"
QIIME2_DIVERSITY_DIR="${QIIME2_DIR}/diversity"
mkdir -p "${QIIME2_PHYLOGENY_DIR}" "${QIIME2_DIVERSITY_DIR}"

QIIME2_ALIGNED_REPSEQS_QZA="${QIIME2_PHYLOGENY_DIR}/aligned-rep-seqs.qza"
QIIME2_MASKED_ALIGNED_REPSEQS_QZA="${QIIME2_PHYLOGENY_DIR}/masked-aligned-rep-seqs.qza"
QIIME2_UNROOTED_TREE_QZA="${QIIME2_PHYLOGENY_DIR}/unrooted-tree.qza"
QIIME2_ROOTED_TREE_QZA="${QIIME2_PHYLOGENY_DIR}/rooted-tree.qza"

QIIME2_ALPHA_DIR="${QIIME2_DIVERSITY_DIR}/alpha"
QIIME2_ALPHA_SHANNON_QZA="${QIIME2_ALPHA_DIR}/shannon.qza"
QIIME2_ALPHA_OBS_QZA="${QIIME2_ALPHA_DIR}/observed_features.qza"
QIIME2_ALPHA_PIELOU_QZA="${QIIME2_ALPHA_DIR}/pielou_e.qza"

QIIME2_ALPHA_SHANNON_EXPORT_DIR="${QIIME2_ALPHA_DIR}/shannon_export"
QIIME2_ALPHA_OBS_EXPORT_DIR="${QIIME2_ALPHA_DIR}/observed_features_export"
QIIME2_ALPHA_PIELOU_EXPORT_DIR="${QIIME2_ALPHA_DIR}/pielou_e_export"

QIIME2_ALPHA_SHANNON_TSV="${QIIME2_ALPHA_SHANNON_EXPORT_DIR}/alpha-diversity.tsv"
QIIME2_ALPHA_OBS_TSV="${QIIME2_ALPHA_OBS_EXPORT_DIR}/alpha-diversity.tsv"
QIIME2_ALPHA_PIELOU_TSV="${QIIME2_ALPHA_PIELOU_EXPORT_DIR}/alpha-diversity.tsv"

mkdir -p "${QIIME2_ALPHA_DIR}"

MANIFEST_R1="/run/sr_amp/inputs/fastq/$(basename "${STAGED_R1}")"
MANIFEST_R2=""
CLASSIFIER_QZA_INNER=""
META_TSV_INNER=""

if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
  MANIFEST_R2="/run/sr_amp/inputs/fastq/$(basename "${STAGED_R2}")"
fi

if [[ -n "${STAGED_CLASSIFIER}" ]]; then
  CLASSIFIER_QZA_INNER="/run/sr_amp/inputs/reference/$(basename "${STAGED_CLASSIFIER}")"
fi

if [[ -n "${STAGED_META_NORMALIZED}" ]]; then
  META_TSV_INNER="/run/sr_amp/inputs/metadata/$(basename "${STAGED_META_NORMALIZED}")"
elif [[ -n "${STAGED_META}" ]]; then
  META_TSV_INNER="/run/sr_amp/inputs/metadata/$(basename "${STAGED_META}")"
fi

if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
  python3 - "${QIIME2_MANIFEST_TSV}" "${SAMPLE_ID}" "${MANIFEST_R1}" "${MANIFEST_R2}" <<'PY'
import sys
out, sample_id, r1, r2 = sys.argv[1:]
with open(out, "w", encoding="utf-8", newline="") as f:
    f.write("sample-id\tforward-absolute-filepath\treverse-absolute-filepath\n")
    f.write(f"{sample_id}\t{r1}\t{r2}\n")
PY
else
  python3 - "${QIIME2_MANIFEST_TSV}" "${SAMPLE_ID}" "${MANIFEST_R1}" <<'PY'
import sys
out, sample_id, r1 = sys.argv[1:]
with open(out, "w", encoding="utf-8", newline="") as f:
    f.write("sample-id\tabsolute-filepath\n")
    f.write(f"{sample_id}\t{r1}\n")
PY
fi

if [[ -n "${STAGED_META_NORMALIZED}" ]]; then
  started="$(iso_now)"
  set +e
  python3 - "${QIIME2_MANIFEST_TSV}" "${STAGED_META_NORMALIZED}" >"${LOGS_DIR}/metadata_validate.log" 2>&1 <<'PY'
import sys

manifest, meta = sys.argv[1:]
man_ids = []
with open(manifest, "r", encoding="utf-8") as f:
    hdr = f.readline()
    for ln in f:
        ln = ln.strip("\n")
        if not ln:
            continue
        man_ids.append(ln.split("\t")[0].strip())

meta_ids = set()
with open(meta, "r", encoding="utf-8", errors="replace") as f:
    lines = [x.rstrip("\n") for x in f if x.strip() and not x.startswith("#")]

if not lines:
    raise SystemExit("ERROR: metadata has no header/rows")

hdr = lines[0].split("\t") if "\t" in lines[0] else lines[0].split(",")
sid_col = 0
for i, c in enumerate(hdr):
    if c.strip().lower() == "sample-id":
        sid_col = i
        break

for ln in lines[1:]:
    parts = ln.split("\t") if "\t" in lines[0] else ln.split(",")
    if len(parts) <= sid_col:
        continue
    meta_ids.add(parts[sid_col].strip())

missing = [x for x in man_ids if x not in meta_ids]
if missing:
    raise SystemExit(f"ERROR: Metadata is missing sample-id(s) required by manifest: {missing}. This would fail QIIME2.")
print("OK: metadata sample-id matches manifest")
PY
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "metadata_validate" "failed" "Metadata missing manifest sample-id (see logs/metadata_validate.log)" "python3" "python3 validate_metadata" "${ec}" "${started}" "${ended}"
    echo "ERROR: Metadata does not match manifest sample-id. See ${LOGS_DIR}/metadata_validate.log" >&2
    exit 2
  fi
  steps_append "${STEPS_JSON}" "metadata_validate" "succeeded" "Metadata contains manifest sample-id" "python3" "python3 validate_metadata" "0" "${started}" "${ended}"
fi

WORK_DIR_HOST="$(jq_first "${CONFIG_PATH}" '.run.work_dir' '.run.output_dir' '.output_dir' '.run.work_dir_host' || true)"
[[ -n "${WORK_DIR_HOST}" ]] || WORK_DIR_HOST=""

REPO_ROOT_HOST=""
if [[ -n "${WORK_DIR_HOST}" ]]; then
  REPO_ROOT_HOST="$(python3 - "${WORK_DIR_HOST}" <<'PY'
import os, sys
w = os.path.realpath(sys.argv[1])
if w.replace("\\","/").endswith("/data/outputs"):
    print(os.path.dirname(os.path.dirname(w)))
else:
    print(os.path.dirname(w))
PY
)"
fi

OUTPUT_DIR_HOST="${OUTPUT_DIR}"
if [[ "${OUTPUT_DIR}" == /work/* ]]; then
  if [[ -z "${REPO_ROOT_HOST}" ]]; then
    echo "ERROR: Need host repo root to mount QIIME2 run dir." >&2
    echo "       Fix: ensure your config has run.work_dir pointing at a host path (like .../main/data/outputs)." >&2
    exit 3
  fi
  OUTPUT_DIR_HOST="${REPO_ROOT_HOST}${OUTPUT_DIR#/work}"
fi

qiime2_cmd_string="docker run --rm --platform=linux/amd64 -v ${OUTPUT_DIR_HOST}:/run:rw ${QIIME2_IMAGE} qiime ..."

if ! command -v docker >/dev/null 2>&1; then
  started="$(iso_now)"; ended="$(iso_now)"
  steps_append "${STEPS_JSON}" "qiime2" "skipped" "docker CLI not available inside SR container (dockerfile.sr must install docker.io)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
else
  started="$(iso_now)"
  set +e
  docker run --rm --platform=linux/amd64 "${QIIME2_IMAGE}" qiime --version >"${QIIME2_LOG}" 2>&1
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "qiime2" "failed" "QIIME2 image failed to run qiime --version (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
    exit 3
  fi

  started="$(iso_now)"
  set +e
  if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime tools import \
        --type 'SampleData[PairedEndSequencesWithQuality]' \
        --input-path "/run/sr_amp/results/qiime2/manifest.tsv" \
        --output-path "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
        --input-format PairedEndFastqManifestPhred33V2 >>"${QIIME2_LOG}" 2>&1
  else
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime tools import \
        --type 'SampleData[SequencesWithQuality]' \
        --input-path "/run/sr_amp/results/qiime2/manifest.tsv" \
        --output-path "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
        --input-format SingleEndFastqManifestPhred33V2 >>"${QIIME2_LOG}" 2>&1
  fi
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "qiime2_import" "failed" "QIIME2 import failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
    exit 3
  else
    steps_append "${STEPS_JSON}" "qiime2_import" "succeeded" "QIIME2 import completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
  fi

  started="$(iso_now)"
  set +e
  docker run --rm --platform=linux/amd64 \
    -v "${OUTPUT_DIR_HOST}:/run:rw" \
    "${QIIME2_IMAGE}" \
    qiime demux summarize \
      --i-data "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
      --o-visualization "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZV}")" >>"${QIIME2_LOG}" 2>&1
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "qiime2_demux_summarize" "failed" "QIIME2 demux summarize failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
    exit 3
  else
    steps_append "${STEPS_JSON}" "qiime2_demux_summarize" "succeeded" "QIIME2 demux summarize completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
  fi

  INPUT_FOR_DADA2="/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")"

  if [[ -n "${PRIMER_FWD}" || -n "${PRIMER_REV}" ]]; then
    if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
      if [[ -n "${PRIMER_FWD}" && -n "${PRIMER_REV}" ]]; then
        started="$(iso_now)"
        set +e
        docker run --rm --platform=linux/amd64 \
          -v "${OUTPUT_DIR_HOST}:/run:rw" \
          "${QIIME2_IMAGE}" \
          qiime cutadapt trim-paired \
            --i-demultiplexed-sequences "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
            --p-front-f "${PRIMER_FWD}" \
            --p-front-r "${PRIMER_REV}" \
            --p-discard-untrimmed \
            --p-cores 1 \
            --o-trimmed-sequences "/run/sr_amp/results/qiime2/trimmed.qza" >>"${QIIME2_LOG}" 2>&1
        ec=$?
        set -e
        ended="$(iso_now)"
        if [[ $ec -ne 0 ]]; then
          steps_append "${STEPS_JSON}" "qiime2_cutadapt" "failed" "cutadapt trim-paired failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
          exit 3
        else
          steps_append "${STEPS_JSON}" "qiime2_cutadapt" "succeeded" "Primer trimming completed (trim-paired)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
          INPUT_FOR_DADA2="/run/sr_amp/results/qiime2/trimmed.qza"
        fi
      else
        started="$(iso_now)"; ended="$(iso_now)"
        steps_append "${STEPS_JSON}" "qiime2_cutadapt" "skipped" "Primer trimming skipped: FASTQ_PAIRED requires both forward and reverse primers" "" "" "0" "${started}" "${ended}"
      fi
    else
      started="$(iso_now)"
      set +e
      if [[ -n "${PRIMER_FWD}" && -n "${PRIMER_REV}" ]]; then
        docker run --rm --platform=linux/amd64 \
          -v "${OUTPUT_DIR_HOST}:/run:rw" \
          "${QIIME2_IMAGE}" \
          qiime cutadapt trim-single \
            --i-demultiplexed-sequences "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
            --p-front "${PRIMER_FWD}" \
            --p-adapter "${PRIMER_REV}" \
            --p-discard-untrimmed \
            --p-cores 1 \
            --o-trimmed-sequences "/run/sr_amp/results/qiime2/trimmed.qza" >>"${QIIME2_LOG}" 2>&1
      elif [[ -n "${PRIMER_FWD}" ]]; then
        docker run --rm --platform=linux/amd64 \
          -v "${OUTPUT_DIR_HOST}:/run:rw" \
          "${QIIME2_IMAGE}" \
          qiime cutadapt trim-single \
            --i-demultiplexed-sequences "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
            --p-front "${PRIMER_FWD}" \
            --p-discard-untrimmed \
            --p-cores 1 \
            --o-trimmed-sequences "/run/sr_amp/results/qiime2/trimmed.qza" >>"${QIIME2_LOG}" 2>&1
      else
        docker run --rm --platform=linux/amd64 \
          -v "${OUTPUT_DIR_HOST}:/run:rw" \
          "${QIIME2_IMAGE}" \
          qiime cutadapt trim-single \
            --i-demultiplexed-sequences "/run/sr_amp/results/qiime2/$(basename "${QIIME2_DEMUX_QZA}")" \
            --p-adapter "${PRIMER_REV}" \
            --p-discard-untrimmed \
            --p-cores 1 \
            --o-trimmed-sequences "/run/sr_amp/results/qiime2/trimmed.qza" >>"${QIIME2_LOG}" 2>&1
      fi
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -ne 0 ]]; then
        steps_append "${STEPS_JSON}" "qiime2_cutadapt" "failed" "cutadapt trim-single failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
        exit 3
      else
        if [[ -n "${PRIMER_FWD}" && -n "${PRIMER_REV}" ]]; then
          steps_append "${STEPS_JSON}" "qiime2_cutadapt" "succeeded" "Primer trimming completed (trim-single; front=FWD, adapter=REV)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
        elif [[ -n "${PRIMER_FWD}" ]]; then
          steps_append "${STEPS_JSON}" "qiime2_cutadapt" "succeeded" "Primer trimming completed (trim-single; front=FWD)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
        else
          steps_append "${STEPS_JSON}" "qiime2_cutadapt" "succeeded" "Primer trimming completed (trim-single; adapter=REV)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
        fi
        INPUT_FOR_DADA2="/run/sr_amp/results/qiime2/trimmed.qza"
      fi
    fi

    if [[ "${INPUT_FOR_DADA2}" == "/run/sr_amp/results/qiime2/trimmed.qza" ]]; then
      started="$(iso_now)"
      set +e
      docker run --rm --platform=linux/amd64 \
        -v "${OUTPUT_DIR_HOST}:/run:rw" \
        "${QIIME2_IMAGE}" \
        qiime demux summarize \
          --i-data "/run/sr_amp/results/qiime2/trimmed.qza" \
          --o-visualization "/run/sr_amp/results/qiime2/trimmed.qzv" >>"${QIIME2_LOG}" 2>&1
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -ne 0 ]]; then
        steps_append "${STEPS_JSON}" "qiime2_trimmed_summarize" "failed" "demux summarize (trimmed) failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
        exit 3
      else
        steps_append "${STEPS_JSON}" "qiime2_trimmed_summarize" "succeeded" "Trimmed demux summarize completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
      fi
    fi
  else
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "qiime2_cutadapt" "skipped" "No primers provided; skipping primer trimming" "" "" "0" "${started}" "${ended}"
  fi

  started="$(iso_now)"
  set +e
  fail_if_missing_files "${QIIME2_MANIFEST_TSV}" "${QIIME2_DEMUX_QZA}" "${QIIME2_DEMUX_QZV}"
  v_ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $v_ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "qiime2_validate_demux" "succeeded" "Found manifest.tsv + demux .qza/.qzv" "" "" "0" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "qiime2_validate_demux" "failed" "Missing expected demux outputs (check logs/qiime2.log)" "" "" "${v_ec}" "${started}" "${ended}"
    echo "ERROR: QIIME2 validation failed (demux outputs missing). See ${QIIME2_LOG}" >&2
    exit 3
  fi

  [[ -n "${DADA2_TRIM_LEFT_F}" ]] || DADA2_TRIM_LEFT_F="0"
  [[ -n "${DADA2_TRIM_LEFT_R}" ]] || DADA2_TRIM_LEFT_R="0"
  [[ -n "${DADA2_TRUNC_LEN_F}" ]] || DADA2_TRUNC_LEN_F="0"
  [[ -n "${DADA2_TRUNC_LEN_R}" ]] || DADA2_TRUNC_LEN_R="0"
  [[ -n "${DADA2_N_THREADS}" ]] || DADA2_N_THREADS="0"

  if [[ "${INPUT_STYLE}" == "FASTQ_PAIRED" ]]; then
    if [[ "${DADA2_TRUNC_LEN_F}" -le 0 || "${DADA2_TRUNC_LEN_R}" -le 0 ]]; then
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "qiime2_dada2" "failed" "DADA2 truncation lengths must be > 0 (qiime2.dada2.trunc_len_f / trunc_len_r)" "" "" "2" "${started}" "${ended}"
      echo "ERROR: DADA2 paired requires trunc_len_f and trunc_len_r > 0" >&2
      exit 2
    fi

    started="$(iso_now)"
    set +e
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime dada2 denoise-paired \
        --i-demultiplexed-seqs "${INPUT_FOR_DADA2}" \
        --p-trim-left-f "${DADA2_TRIM_LEFT_F}" \
        --p-trim-left-r "${DADA2_TRIM_LEFT_R}" \
        --p-trunc-len-f "${DADA2_TRUNC_LEN_F}" \
        --p-trunc-len-r "${DADA2_TRUNC_LEN_R}" \
        --p-trunc-q 0 \
        --p-max-ee-f 15 \
        --p-max-ee-r 15 \
        --p-n-threads "${DADA2_N_THREADS}" \
        --o-table "/run/sr_amp/results/qiime2/table.qza" \
        --o-representative-sequences "/run/sr_amp/results/qiime2/rep-seqs.qza" \
        --o-denoising-stats "/run/sr_amp/results/qiime2/denoising-stats.qza" >>"${QIIME2_LOG}" 2>&1
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 ]]; then
      steps_append "${STEPS_JSON}" "qiime2_dada2" "failed" "DADA2 denoise-paired failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
      exit 3
    else
      steps_append "${STEPS_JSON}" "qiime2_dada2" "succeeded" "DADA2 denoise-paired completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
    fi
  else
    if [[ "${DADA2_TRUNC_LEN_F}" -le 0 ]]; then
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "qiime2_dada2" "failed" "DADA2 truncation length must be > 0 (qiime2.dada2.trunc_len_f) for single-end" "" "" "2" "${started}" "${ended}"
      echo "ERROR: DADA2 single requires trunc_len_f > 0" >&2
      exit 2
    fi

    started="$(iso_now)"
    set +e
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime dada2 denoise-single \
        --i-demultiplexed-seqs "${INPUT_FOR_DADA2}" \
        --p-trim-left "${DADA2_TRIM_LEFT_F}" \
        --p-trunc-len "${DADA2_TRUNC_LEN_F}" \
        --p-trunc-q 0 \
        --p-max-ee-f 15 \
        --p-n-threads "${DADA2_N_THREADS}" \
        --o-table "/run/sr_amp/results/qiime2/table.qza" \
        --o-representative-sequences "/run/sr_amp/results/qiime2/rep-seqs.qza" \
        --o-denoising-stats "/run/sr_amp/results/qiime2/denoising-stats.qza" >>"${QIIME2_LOG}" 2>&1
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 ]]; then
      steps_append "${STEPS_JSON}" "qiime2_dada2" "failed" "DADA2 denoise-single failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
      exit 3
    else
      steps_append "${STEPS_JSON}" "qiime2_dada2" "succeeded" "DADA2 denoise-single completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
    fi
  fi

  started="$(iso_now)"
  set +e
  docker run --rm --platform=linux/amd64 \
    -v "${OUTPUT_DIR_HOST}:/run:rw" \
    "${QIIME2_IMAGE}" \
    qiime feature-table summarize \
      --i-table "/run/sr_amp/results/qiime2/table.qza" \
      --o-visualization "/run/sr_amp/results/qiime2/table.qzv" >>"${QIIME2_LOG}" 2>&1
  ec=$?
  set -e
  ended="$(iso_now)"
  [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_table_summarize" "failed" "feature-table summarize failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
  steps_append "${STEPS_JSON}" "qiime2_table_summarize" "succeeded" "feature-table summarize completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"

  started="$(iso_now)"
  set +e
  docker run --rm --platform=linux/amd64 \
    -v "${OUTPUT_DIR_HOST}:/run:rw" \
    "${QIIME2_IMAGE}" \
    qiime feature-table tabulate-seqs \
      --i-data "/run/sr_amp/results/qiime2/rep-seqs.qza" \
      --o-visualization "/run/sr_amp/results/qiime2/rep-seqs.qzv" >>"${QIIME2_LOG}" 2>&1
  ec=$?
  set -e
  ended="$(iso_now)"
  [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_repseqs_tabulate" "failed" "tabulate-seqs failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
  steps_append "${STEPS_JSON}" "qiime2_repseqs_tabulate" "succeeded" "tabulate-seqs completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"

  started="$(iso_now)"
  set +e
  docker run --rm --platform=linux/amd64 \
    -v "${OUTPUT_DIR_HOST}:/run:rw" \
    "${QIIME2_IMAGE}" \
    qiime metadata tabulate \
      --m-input-file "/run/sr_amp/results/qiime2/denoising-stats.qza" \
      --o-visualization "/run/sr_amp/results/qiime2/denoising-stats.qzv" >>"${QIIME2_LOG}" 2>&1
  ec=$?
  set -e
  ended="$(iso_now)"
  [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_denoising_stats_tabulate" "failed" "denoising-stats tabulate failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
  steps_append "${STEPS_JSON}" "qiime2_denoising_stats_tabulate" "succeeded" "denoising-stats tabulate completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"

  if [[ -n "${CLASSIFIER_QZA_INNER}" ]]; then
    started="$(iso_now)"
    set +e
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime feature-classifier classify-sklearn \
        --i-classifier "${CLASSIFIER_QZA_INNER}" \
        --i-reads "/run/sr_amp/results/qiime2/rep-seqs.qza" \
        --o-classification "/run/sr_amp/results/qiime2/taxonomy.qza" >>"${QIIME2_LOG}" 2>&1
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 ]]; then
      steps_append "${STEPS_JSON}" "qiime2_taxonomy" "failed" "classify-sklearn failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
      exit 3
    else
      steps_append "${STEPS_JSON}" "qiime2_taxonomy" "succeeded" "Taxonomy classification completed (classify-sklearn)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
    fi

    started="$(iso_now)"
    set +e
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime metadata tabulate \
        --m-input-file "/run/sr_amp/results/qiime2/taxonomy.qza" \
        --o-visualization "/run/sr_amp/results/qiime2/taxonomy.qzv" >>"${QIIME2_LOG}" 2>&1
    ec=$?
    set -e
    ended="$(iso_now)"
    [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_taxonomy_tabulate" "failed" "taxonomy tabulate failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
    steps_append "${STEPS_JSON}" "qiime2_taxonomy_tabulate" "succeeded" "taxonomy.qzv created" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"

    if [[ -n "${META_TSV_INNER}" ]]; then
      started="$(iso_now)"
      set +e
      docker run --rm --platform=linux/amd64 \
        -v "${OUTPUT_DIR_HOST}:/run:rw" \
        "${QIIME2_IMAGE}" \
        qiime taxa barplot \
          --i-table "/run/sr_amp/results/qiime2/table.qza" \
          --i-taxonomy "/run/sr_amp/results/qiime2/taxonomy.qza" \
          --m-metadata-file "${META_TSV_INNER}" \
          --o-visualization "/run/sr_amp/results/qiime2/taxa-barplot.qzv" >>"${QIIME2_LOG}" 2>&1
      ec=$?
      set -e
      ended="$(iso_now)"
      [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_taxa_barplot" "failed" "taxa barplot failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
      steps_append "${STEPS_JSON}" "qiime2_taxa_barplot" "succeeded" "taxa-barplot.qzv created" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
    else
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "qiime2_taxa_barplot" "skipped" "No metadata TSV provided; skipping taxa barplot" "" "" "0" "${started}" "${ended}"
    fi
  else
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "qiime2_taxonomy" "skipped" "No classifier provided; skipping taxonomy" "" "" "0" "${started}" "${ended}"
  fi

  # -----------------------------
  # Diversity
  # -----------------------------
  MANIFEST_N_SAMPLES="$(python3 - "${QIIME2_MANIFEST_TSV}" <<'PY'
import sys
p = sys.argv[1]
n = 0
with open(p, "r", encoding="utf-8") as f:
    f.readline()
    for ln in f:
        if ln.strip():
            n += 1
print(n)
PY
)"

  rm -rf "${QIIME2_ALPHA_SHANNON_EXPORT_DIR}" "${QIIME2_ALPHA_OBS_EXPORT_DIR}" "${QIIME2_ALPHA_PIELOU_EXPORT_DIR}"

  started="$(iso_now)"
  set +e

  docker run --rm --platform=linux/amd64 \
    -v "${OUTPUT_DIR_HOST}:/run:rw" \
    "${QIIME2_IMAGE}" \
    qiime diversity alpha \
      --i-table "/run/sr_amp/results/qiime2/table.qza" \
      --p-metric shannon \
      --o-alpha-diversity "/run/sr_amp/results/qiime2/diversity/alpha/shannon.qza" >>"${QIIME2_LOG}" 2>&1
  ec=$?

  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime diversity alpha \
        --i-table "/run/sr_amp/results/qiime2/table.qza" \
        --p-metric observed_features \
        --o-alpha-diversity "/run/sr_amp/results/qiime2/diversity/alpha/observed_features.qza" >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime diversity alpha \
        --i-table "/run/sr_amp/results/qiime2/table.qza" \
        --p-metric pielou_e \
        --o-alpha-diversity "/run/sr_amp/results/qiime2/diversity/alpha/pielou_e.qza" >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime tools export \
        --input-path "/run/sr_amp/results/qiime2/diversity/alpha/shannon.qza" \
        --output-path "/run/sr_amp/results/qiime2/diversity/alpha/shannon_export" >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime tools export \
        --input-path "/run/sr_amp/results/qiime2/diversity/alpha/observed_features.qza" \
        --output-path "/run/sr_amp/results/qiime2/diversity/alpha/observed_features_export" >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime tools export \
        --input-path "/run/sr_amp/results/qiime2/diversity/alpha/pielou_e.qza" \
        --output-path "/run/sr_amp/results/qiime2/diversity/alpha/pielou_e_export" >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  set -e
  ended="$(iso_now)"

  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "qiime2_diversity_alpha" "failed" "Alpha diversity failed (shannon/observed_features/pielou_e). See logs/qiime2.log" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"
    exit 3
  else
    steps_append "${STEPS_JSON}" "qiime2_diversity_alpha" "succeeded" "Alpha diversity exported (shannon, observed_features, pielou_e)" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
  fi

  if [[ -n "${SAMPLING_DEPTH}" && "${SAMPLING_DEPTH}" -gt 0 ]]; then
    if [[ "${MANIFEST_N_SAMPLES}" -lt 2 ]]; then
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "qiime2_diversity_core" "skipped" "Core metrics skipped: requires >=2 samples; manifest has ${MANIFEST_N_SAMPLES}" "" "" "0" "${started}" "${ended}"
    else
      if [[ -z "${META_TSV_INNER}" ]]; then
        started="$(iso_now)"; ended="$(iso_now)"
        steps_append "${STEPS_JSON}" "qiime2_diversity_core" "failed" "Core metrics requested (sampling_depth>0) but no metadata TSV provided (qiime2.diversity.metadata_tsv)" "" "" "2" "${started}" "${ended}"
        echo "ERROR: Core metrics requested but metadata TSV is missing." >&2
        exit 2
      fi

      started="$(iso_now)"
      set +e
      docker run --rm --platform=linux/amd64 \
        -v "${OUTPUT_DIR_HOST}:/run:rw" \
        "${QIIME2_IMAGE}" \
        qiime phylogeny align-to-tree-mafft-fasttree \
          --i-sequences "/run/sr_amp/results/qiime2/rep-seqs.qza" \
          --o-alignment "/run/sr_amp/results/qiime2/phylogeny/aligned-rep-seqs.qza" \
          --o-masked-alignment "/run/sr_amp/results/qiime2/phylogeny/masked-aligned-rep-seqs.qza" \
          --o-tree "/run/sr_amp/results/qiime2/phylogeny/unrooted-tree.qza" \
          --o-rooted-tree "/run/sr_amp/results/qiime2/phylogeny/rooted-tree.qza" >>"${QIIME2_LOG}" 2>&1
      ec=$?
      set -e
      ended="$(iso_now)"
      [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_phylogeny" "failed" "align-to-tree failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
      steps_append "${STEPS_JSON}" "qiime2_phylogeny" "succeeded" "Phylogeny created" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"

      started="$(iso_now)"
      set +e
      docker run --rm --platform=linux/amd64 \
        -v "${OUTPUT_DIR_HOST}:/run:rw" \
        "${QIIME2_IMAGE}" \
        qiime diversity core-metrics-phylogenetic \
          --i-phylogeny "/run/sr_amp/results/qiime2/phylogeny/rooted-tree.qza" \
          --i-table "/run/sr_amp/results/qiime2/table.qza" \
          --p-sampling-depth "${SAMPLING_DEPTH}" \
          --m-metadata-file "${META_TSV_INNER}" \
          --output-dir "/run/sr_amp/results/qiime2/diversity/core-metrics-results" >>"${QIIME2_LOG}" 2>&1
      ec=$?
      set -e
      ended="$(iso_now)"
      [[ $ec -eq 0 ]] || { steps_append "${STEPS_JSON}" "qiime2_diversity_core" "failed" "core-metrics-phylogenetic failed (see logs/qiime2.log)" "docker" "${qiime2_cmd_string}" "${ec}" "${started}" "${ended}"; exit 3; }
      steps_append "${STEPS_JSON}" "qiime2_diversity_core" "succeeded" "Core metrics completed" "docker" "${qiime2_cmd_string}" "0" "${started}" "${ended}"
    fi
  else
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "qiime2_diversity_core" "skipped" "Core metrics skipped: sampling_depth not set (>0 required)" "" "" "0" "${started}" "${ended}"
  fi

  # -----------------------------
  # Append qiime2 artifacts to outputs.json
  # -----------------------------
  tmp="${OUTPUTS_JSON}.tmp"
  jq --arg qiime2_dir "${QIIME2_DIR}" \
     --arg qiime2_log "${QIIME2_LOG}" \
     --arg qiime2_manifest_tsv "${QIIME2_MANIFEST_TSV}" \
     --arg qiime2_demux_qza "${QIIME2_DEMUX_QZA}" \
     --arg qiime2_demux_qzv "${QIIME2_DEMUX_QZV}" \
     --arg qiime2_trimmed_qza "${QIIME2_TRIMMED_QZA}" \
     --arg qiime2_trimmed_qzv "${QIIME2_TRIMMED_QZV}" \
     --arg qiime2_table_qza "${QIIME2_TABLE_QZA}" \
     --arg qiime2_repseq_qza "${QIIME2_REPSEQ_QZA}" \
     --arg qiime2_dada2_stats_qza "${QIIME2_DADA2_STATS_QZA}" \
     --arg qiime2_table_qzv "${QIIME2_TABLE_QZV}" \
     --arg qiime2_repseq_qzv "${QIIME2_REPSEQ_QZV}" \
     --arg qiime2_dada2_stats_qzv "${QIIME2_DADA2_STATS_QZV}" \
     --arg qiime2_taxonomy_qza "${QIIME2_TAXONOMY_QZA}" \
     --arg qiime2_taxonomy_qzv "${QIIME2_TAXONOMY_QZV}" \
     --arg qiime2_taxa_barplot_qzv "${QIIME2_TAXA_BARPLOT_QZV}" \
     --arg qiime2_rooted_tree_qza "${QIIME2_ROOTED_TREE_QZA}" \
     --arg qiime2_diversity_core_dir "${QIIME2_DIVERSITY_DIR}/core-metrics-results" \
     --arg qiime2_alpha_dir "${QIIME2_ALPHA_DIR}" \
     --arg qiime2_alpha_shannon_tsv "${QIIME2_ALPHA_SHANNON_TSV}" \
     --arg qiime2_alpha_observed_features_tsv "${QIIME2_ALPHA_OBS_TSV}" \
     --arg qiime2_alpha_pielou_e_tsv "${QIIME2_ALPHA_PIELOU_TSV}" \
     '. + {
        qiime2_dir: $qiime2_dir,
        qiime2_log: $qiime2_log,
        qiime2_artifacts: {
          manifest_tsv: $qiime2_manifest_tsv,
          demux_qza: $qiime2_demux_qza,
          demux_qzv: $qiime2_demux_qzv,
          trimmed_qza: ($qiime2_trimmed_qza | select(length>0) // null),
          trimmed_qzv: ($qiime2_trimmed_qzv | select(length>0) // null),
          table_qza: $qiime2_table_qza,
          rep_seqs_qza: $qiime2_repseq_qza,
          denoising_stats_qza: $qiime2_dada2_stats_qza,
          table_qzv: $qiime2_table_qzv,
          rep_seqs_qzv: $qiime2_repseq_qzv,
          denoising_stats_qzv: $qiime2_dada2_stats_qzv,
          taxonomy_qza: ($qiime2_taxonomy_qza | select(length>0) // null),
          taxonomy_qzv: ($qiime2_taxonomy_qzv | select(length>0) // null),
          taxa_barplot_qzv: ($qiime2_taxa_barplot_qzv | select(length>0) // null),
          rooted_tree_qza: ($qiime2_rooted_tree_qza | select(length>0) // null),

          alpha_diversity_dir: ($qiime2_alpha_dir | select(length>0) // null),
          alpha_diversity_tsv: {
            shannon: ($qiime2_alpha_shannon_tsv | select(length>0) // null),
            observed_features: ($qiime2_alpha_observed_features_tsv | select(length>0) // null),
            pielou_e: ($qiime2_alpha_pielou_e_tsv | select(length>0) // null)
          },

          diversity_core_metrics_dir: ($qiime2_diversity_core_dir | select(length>0) // null)
        }
      }' "${OUTPUTS_JSON}" > "${tmp}"
  mv "${tmp}" "${OUTPUTS_JSON}"

  # -----------------------------
  # QIIME2 EXPORTS (requested)
  # After QIIME is done:
  #   - export table.qza -> BIOM + TSV
  #   - export rep-seqs.qza -> FASTA
  #   - export taxonomy.qza -> TSV
  # -----------------------------
  QIIME2_EXPORTS_DIR="${QIIME2_DIR}/exports"
  QIIME2_EXPORT_TABLE_DIR="${QIIME2_EXPORTS_DIR}/table"
  QIIME2_EXPORT_REPSEQS_DIR="${QIIME2_EXPORTS_DIR}/rep-seqs"
  QIIME2_EXPORT_TAXONOMY_DIR="${QIIME2_EXPORTS_DIR}/taxonomy"

  QIIME2_EXPORT_TABLE_BIOM="${QIIME2_EXPORT_TABLE_DIR}/feature-table.biom"
  QIIME2_EXPORT_TABLE_TSV="${QIIME2_EXPORT_TABLE_DIR}/feature-table.tsv"
  QIIME2_EXPORT_REPSEQS_FASTA="${QIIME2_EXPORT_REPSEQS_DIR}/dna-sequences.fasta"
  QIIME2_EXPORT_TAXONOMY_TSV="${QIIME2_EXPORT_TAXONOMY_DIR}/taxonomy.tsv"

  rm -rf "${QIIME2_EXPORT_TABLE_DIR}" "${QIIME2_EXPORT_REPSEQS_DIR}" "${QIIME2_EXPORT_TAXONOMY_DIR}"
  mkdir -p "${QIIME2_EXPORT_TABLE_DIR}" "${QIIME2_EXPORT_REPSEQS_DIR}" "${QIIME2_EXPORT_TAXONOMY_DIR}"

  started="$(iso_now)"
  set +e

  # table.qza -> biom + tsv
  docker run --rm --platform=linux/amd64 \
    -v "${OUTPUT_DIR_HOST}:/run:rw" \
    "${QIIME2_IMAGE}" \
    qiime tools export \
      --input-path "/run/sr_amp/results/qiime2/table.qza" \
      --output-path "/run/sr_amp/results/qiime2/exports/table" >>"${QIIME2_LOG}" 2>&1
  ec=$?

  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      biom convert \
        -i "/run/sr_amp/results/qiime2/exports/table/feature-table.biom" \
        -o "/run/sr_amp/results/qiime2/exports/table/feature-table.tsv" \
        --to-tsv >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  # rep-seqs.qza -> fasta
  if [[ $ec -eq 0 ]]; then
    docker run --rm --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      qiime tools export \
        --input-path "/run/sr_amp/results/qiime2/rep-seqs.qza" \
        --output-path "/run/sr_amp/results/qiime2/exports/rep-seqs" >>"${QIIME2_LOG}" 2>&1
    ec=$?
  fi

  # taxonomy.qza -> tsv (only if taxonomy exists)
  if [[ $ec -eq 0 ]]; then
    if [[ -f "${QIIME2_TAXONOMY_QZA}" ]]; then
      docker run --rm --platform=linux/amd64 \
        -v "${OUTPUT_DIR_HOST}:/run:rw" \
        "${QIIME2_IMAGE}" \
        qiime tools export \
          --input-path "/run/sr_amp/results/qiime2/taxonomy.qza" \
          --output-path "/run/sr_amp/results/qiime2/exports/taxonomy" >>"${QIIME2_LOG}" 2>&1
      ec=$?
    else
      ec=0
      started2="$(iso_now)"; ended2="$(iso_now)"
      steps_append "${STEPS_JSON}" "qiime2_export_taxonomy" "skipped" "taxonomy.qza not present; skipping taxonomy export" "" "" "0" "${started2}" "${ended2}"
    fi
  fi

  set -e
  ended="$(iso_now)"

  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "qiime2_exports" "failed" "QIIME2 exports failed (table/rep-seqs/taxonomy). See logs/qiime2.log" "docker" "qiime tools export + biom convert" "${ec}" "${started}" "${ended}"
    exit 3
  else
    # Validate expected export files (taxonomy is optional)
    fail_if_missing_files "${QIIME2_EXPORT_TABLE_BIOM}" "${QIIME2_EXPORT_TABLE_TSV}" "${QIIME2_EXPORT_REPSEQS_FASTA}"
    v_ec=$?
    if [[ $v_ec -ne 0 ]]; then
      steps_append "${STEPS_JSON}" "qiime2_exports" "failed" "QIIME2 exports missing expected files (table biom/tsv and/or rep-seqs fasta)" "" "" "${v_ec}" "${started}" "${ended}"
      exit 3
    fi
    steps_append "${STEPS_JSON}" "qiime2_exports" "succeeded" "Exported table (BIOM+TSV), rep-seqs (FASTA), taxonomy (TSV when available)" "docker" "qiime tools export + biom convert" "0" "${started}" "${ended}"

    tmp="${OUTPUTS_JSON}.tmp"
    jq --arg exports_dir "${QIIME2_EXPORTS_DIR}" \
       --arg table_biom "${QIIME2_EXPORT_TABLE_BIOM}" \
       --arg table_tsv "${QIIME2_EXPORT_TABLE_TSV}" \
       --arg repseqs_fasta "${QIIME2_EXPORT_REPSEQS_FASTA}" \
       --arg taxonomy_tsv "${QIIME2_EXPORT_TAXONOMY_TSV}" \
       '. + {
          qiime2_exports: {
            dir: $exports_dir,
            table_biom: ($table_biom | select(length>0) // null),
            table_tsv: ($table_tsv | select(length>0) // null),
            rep_seqs_fasta: ($repseqs_fasta | select(length>0) // null),
            taxonomy_tsv: ( ( $taxonomy_tsv | select(length>0) ) // null )
          }
        }' "${OUTPUTS_JSON}" > "${tmp}"
    mv "${tmp}" "${OUTPUTS_JSON}"
  fi

  # -----------------------------
  # VALENCIA (adjusted outputs as requested)
  # -----------------------------
  VALENCIA_ENABLED_RAW="$(jq_first "${CONFIG_PATH}" '.valencia.enabled' '.qiime2.valencia.enabled' '.valencia_enabled' '.tools.valencia.enabled' || true)"
  VALENCIA_CENTROIDS_HOST="$(jq_first "${CONFIG_PATH}" '.valencia.centroids_csv' '.qiime2.valencia.centroids_csv' '.tools.valencia.centroids_csv' || true)"
  SAMPLE_TYPE_RAW="$(jq_first "${CONFIG_PATH}" '.sample_type' '.input.sample_type' '.inputs.sample_type' '.run.sample_type' '.run.sample_type_resolved' || true)"

  # Normalize enabled flag (allow: true/false/auto/1/0)
  VALENCIA_ENABLED="auto"
  if [[ -n "${VALENCIA_ENABLED_RAW}" ]]; then
    case "$(printf "%s" "${VALENCIA_ENABLED_RAW}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      1|true|yes|y) VALENCIA_ENABLED="true" ;;
      0|false|no|n) VALENCIA_ENABLED="false" ;;
      auto|"") VALENCIA_ENABLED="auto" ;;
      *) VALENCIA_ENABLED="${VALENCIA_ENABLED_RAW}" ;;
    esac
  fi

  SAMPLE_TYPE_NORM="$(printf "%s" "${SAMPLE_TYPE_RAW}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

  VALENCIA_DIR="${RESULTS_DIR}/valencia"
  VALENCIA_LOG="${LOGS_DIR}/valencia.log"
  mkdir -p "${VALENCIA_DIR}"

  STAGED_VALENCIA_CENTROIDS=""
  if [[ -n "${VALENCIA_CENTROIDS_HOST}" && "${VALENCIA_CENTROIDS_HOST}" != "null" ]]; then
    VALENCIA_CENTROIDS_HOST="$(printf "%s" "${VALENCIA_CENTROIDS_HOST}" | tr -d '\r\n')"
    require_file "${VALENCIA_CENTROIDS_HOST}"
    STAGED_VALENCIA_CENTROIDS="${REF_STAGE_DIR}/$(basename "${VALENCIA_CENTROIDS_HOST}")"
    rm -f "${STAGED_VALENCIA_CENTROIDS}"
    cp -f "${VALENCIA_CENTROIDS_HOST}" "${STAGED_VALENCIA_CENTROIDS}"
  fi

  VALENCIA_SHOULD_RUN="no"
  if [[ "${VALENCIA_ENABLED}" == "true" ]]; then
    VALENCIA_SHOULD_RUN="yes"
  elif [[ "${VALENCIA_ENABLED}" == "auto" ]]; then
    # auto: only run for vaginal sample_type (if present)
    if [[ "${SAMPLE_TYPE_NORM}" == "vaginal" ]]; then
      VALENCIA_SHOULD_RUN="yes"
    else
      VALENCIA_SHOULD_RUN="no"
    fi
  else
    VALENCIA_SHOULD_RUN="no"
  fi

  if [[ "${VALENCIA_SHOULD_RUN}" != "yes" ]]; then
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "valencia" "skipped" "VALENCIA skipped (enabled=${VALENCIA_ENABLED}, sample_type=${SAMPLE_TYPE_RAW:-})" "" "" "0" "${started}" "${ended}"
  else
    # Require taxonomy + table exports (VALENCIA needs condensed taxa + sample x taxa table)
    if [[ ! -f "${QIIME2_EXPORT_TABLE_TSV}" || ! -f "${QIIME2_EXPORT_TABLE_BIOM}" ]]; then
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "valencia" "failed" "VALENCIA requires QIIME2 exported table (feature-table.tsv/biom), but exports are missing" "" "" "2" "${started}" "${ended}"
      echo "ERROR: VALENCIA requires QIIME2 exports. Missing: ${QIIME2_EXPORT_TABLE_TSV} and/or ${QIIME2_EXPORT_TABLE_BIOM}" >&2
      exit 2
    fi

    if [[ ! -f "${QIIME2_EXPORT_TAXONOMY_TSV}" ]]; then
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "valencia" "failed" "VALENCIA requires exported taxonomy.tsv, but taxonomy export is missing (provide classifier and rerun)" "" "" "2" "${started}" "${ended}"
      echo "ERROR: VALENCIA requires taxonomy.tsv export. Provide qiime2.classifier.qza so taxonomy.qza can be created and exported." >&2
      exit 2
    fi

    if [[ -z "${STAGED_VALENCIA_CENTROIDS}" ]]; then
      started="$(iso_now)"; ended="$(iso_now)"
      steps_append "${STEPS_JSON}" "valencia" "failed" "VALENCIA enabled, but no centroids CSV provided. Set valencia.centroids_csv in config." "" "" "2" "${started}" "${ended}"
      echo "ERROR: VALENCIA enabled but centroids CSV missing. Set valencia.centroids_csv (or qiime2.valencia.centroids_csv/tools.valencia.centroids_csv)." >&2
      exit 2
    fi

    VALENCIA_CENTROIDS_INNER="/run/sr_amp/inputs/reference/$(basename "${STAGED_VALENCIA_CENTROIDS}")"
    VALENCIA_INNER_DIR="/run/sr_amp/results/valencia"

    # Requested outputs:
    #  - input file used by VALENCIA (sample x condensed taxa): taxon_table_asv_merged.csv
    #  - VALENCIA results: output.csv (plus keep valencia_assignments.csv for compatibility)
    #  - plots directory (simple SVG similarity barplots)
    VALENCIA_INPUT_CSV="${VALENCIA_DIR}/taxon_table_asv_merged.csv"
    VALENCIA_ASV_TAXA_CSV="${VALENCIA_DIR}/asv_condensed_taxa_names.csv"
    VALENCIA_OUTPUT_CSV="${VALENCIA_DIR}/output.csv"
    VALENCIA_ASSIGNMENTS_CSV="${VALENCIA_DIR}/valencia_assignments.csv"
    VALENCIA_PLOTS_DIR="${VALENCIA_DIR}/plots"

    started="$(iso_now)"
    set +e
    docker run --rm -i --platform=linux/amd64 \
      -v "${OUTPUT_DIR_HOST}:/run:rw" \
      "${QIIME2_IMAGE}" \
      python3 - "${VALENCIA_CENTROIDS_INNER}" "/run/sr_amp/results/qiime2/exports/taxonomy/taxonomy.tsv" "/run/sr_amp/results/qiime2/exports/table/feature-table.tsv" "${VALENCIA_INNER_DIR}" >>"${VALENCIA_LOG}" 2>&1 <<'PY'
import sys, os, re, csv, math

centroids_csv, taxonomy_tsv, feature_table_tsv, out_dir = sys.argv[1:]
os.makedirs(out_dir, exist_ok=True)
plots_dir = os.path.join(out_dir, "plots")
os.makedirs(plots_dir, exist_ok=True)

# -----------------------------
# Helpers: taxonomy parsing
# -----------------------------
bc_focal = {'Lactobacillus','Prevotella','Gardnerella','Atopobium','Sneathia'}

def strip_prefix(x: str) -> str:
    x = (x or "").strip()
    x = re.sub(r"^[A-Za-z0-9_]+__+", "", x)   # k__Bacteria or D_0__Bacteria
    x = re.sub(r"^[A-Za-z]\s*__+", "", x)
    return x.strip()

def parse_taxon_string(s: str):
    ranks = {"k": "", "p": "", "c": "", "o": "", "f": "", "g": "", "s": ""}
    if not isinstance(s, str) or not s.strip():
        return ranks
    parts = [p.strip() for p in s.split(";") if p.strip()]
    for p in parts:
        m = re.match(r"^(k|p|c|o|f|g|s)\s*__", p)
        if m:
            key = m.group(1)
            ranks[key] = strip_prefix(p)
            continue
        m2 = re.match(r"^D_(\d+)__", p)
        if m2:
            idx = int(m2.group(1))
            key = {0:"k",1:"p",2:"c",3:"o",4:"f",5:"g",6:"s"}.get(idx)
            if key:
                ranks[key] = strip_prefix(p)
            continue
    return ranks

def taxon_condense(ranks: dict) -> str:
    # replicate convert_qiime.py: reverse ranks and pick first non-empty
    order = ["s","g","f","o","c","p","k"]
    first = None
    for k in order:
        v = (ranks.get(k) or "").strip()
        if v:
            first = k
            break
    if first is None:
        return "None"

    if first == "s":
        g = (ranks.get("g") or "").strip()
        s = (ranks.get("s") or "").strip()
        if g in bc_focal and s:
            name = f"{g}_{s}"
        elif g:
            name = f"g_{g}"
        else:
            name = f"s_{s}" if s else "None"
    elif first == "g":
        name = f"g_{(ranks.get('g') or '').strip()}"
    elif first == "f":
        name = f"f_{(ranks.get('f') or '').strip()}"
    elif first == "o":
        name = f"o_{(ranks.get('o') or '').strip()}"
    elif first == "c":
        name = f"c_{(ranks.get('c') or '').strip()}"
    elif first == "p":
        name = f"p_{(ranks.get('p') or '').strip()}"
    else:
        name = f"k_{(ranks.get('k') or '').strip()}"

    # manual corrections from convert_qiime.py
    fixes = {
        'g_Gardnerella':'Gardnerella_vaginalis',
        'Lactobacillus_acidophilus/casei/crispatus/gallinarum':'Lactobacillus_crispatus',
        'Lactobacillus_fornicalis/jensenii':'Lactobacillus_jensenii',
        'g_Escherichia/Shigella':'g_Escherichia.Shigella',
        'Lactobacillus_gasseri/johnsonii':'Lactobacillus_gasseri'
    }
    return fixes.get(name, name)

# -----------------------------
# Read taxonomy.tsv -> FeatureID -> condensed taxa, plus ranks
# -----------------------------
feature_to = {}  # FeatureID -> {"taxa":..., "k":..., ...}
with open(taxonomy_tsv, "r", encoding="utf-8", errors="replace", newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")
    if "Feature ID" not in reader.fieldnames or "Taxon" not in reader.fieldnames:
        raise SystemExit("ERROR: taxonomy.tsv missing required columns (Feature ID, Taxon)")
    for row in reader:
        fid = (row.get("Feature ID") or "").strip()
        taxon = row.get("Taxon") or ""
        ranks = parse_taxon_string(taxon)
        taxa = taxon_condense(ranks)
        feature_to[fid] = {"taxa": taxa, **ranks}

if not feature_to:
    raise SystemExit("ERROR: taxonomy.tsv appears empty after parsing")

# -----------------------------
# Read feature-table.tsv (biom convert output) -> sample x ASV counts
# -----------------------------
# Find the '#OTU ID' header line, then parse tab-separated table.
lines = []
with open(feature_table_tsv, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

hdr_idx = None
for i, ln in enumerate(lines):
    if ln.startswith("#OTU ID"):
        hdr_idx = i
        break
if hdr_idx is None:
    raise SystemExit("ERROR: feature-table.tsv did not contain a '#OTU ID' header (biom convert output unexpected)")

header = lines[hdr_idx].split("\t")
if len(header) < 2:
    raise SystemExit("ERROR: feature-table.tsv header too short")

sample_ids = header[1:]
# counts_by_sample_taxa[sample][taxa] = count
counts_by_sample_taxa = {s: {} for s in sample_ids}
read_count_by_sample = {s: 0 for s in sample_ids}

for ln in lines[hdr_idx+1:]:
    if not ln.strip():
        continue
    parts = ln.split("\t")
    if len(parts) < 2:
        continue
    fid = parts[0].strip()
    taxa = feature_to.get(fid, {}).get("taxa", "None")
    # numeric counts for each sample col
    for j, s in enumerate(sample_ids, start=1):
        if j >= len(parts):
            v = 0
        else:
            try:
                v = int(float(parts[j]))
            except Exception:
                v = 0
        if v <= 0:
            continue
        counts_by_sample_taxa[s][taxa] = counts_by_sample_taxa[s].get(taxa, 0) + v
        read_count_by_sample[s] += v

# Build condensed taxa list sorted by total abundance desc
taxa_totals = {}
for s in sample_ids:
    for taxa, v in counts_by_sample_taxa[s].items():
        taxa_totals[taxa] = taxa_totals.get(taxa, 0) + v
taxa_cols = [t for t, _ in sorted(taxa_totals.items(), key=lambda kv: kv[1], reverse=True)]

# Write input CSV for VALENCIA: samples are rows, condensed taxa are cols
taxon_table_csv = os.path.join(out_dir, "taxon_table_asv_merged.csv")
with open(taxon_table_csv, "w", encoding="utf-8", newline="") as out:
    w = csv.writer(out)
    w.writerow(["sampleID", "read_count", *taxa_cols])
    for s in sample_ids:
        row = [s, read_count_by_sample.get(s, 0)]
        row.extend([counts_by_sample_taxa[s].get(t, 0) for t in taxa_cols])
        w.writerow(row)

# Write ASV condensed taxa key (FeatureID -> condensed taxa + ranks)
asv_taxa_csv = os.path.join(out_dir, "asv_condensed_taxa_names.csv")
with open(asv_taxa_csv, "w", encoding="utf-8", newline="") as out:
    w = csv.writer(out)
    w.writerow(["FeatureID", "taxa", "k", "p", "c", "o", "f", "g", "s"])
    for fid, info in feature_to.items():
        w.writerow([fid, info.get("taxa",""), info.get("k",""), info.get("p",""), info.get("c",""), info.get("o",""), info.get("f",""), info.get("g",""), info.get("s","")])

# -----------------------------
# Run VALENCIA classification (nearest centroid on relative abundances)
# -----------------------------
# Load centroids: expect a column 'sub_CST' and taxa columns.
centroid_rows = []
with open(centroids_csv, "r", encoding="utf-8", errors="replace", newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("ERROR: centroids CSV appears empty")
    fields = list(reader.fieldnames)

    # tolerate subCST naming variant
    if "sub_CST" not in fields and "subCST" in fields:
        fields = ["sub_CST" if x == "subCST" else x for x in fields]

    if "sub_CST" not in fields:
        raise SystemExit("ERROR: centroids CSV missing 'sub_CST' column")

    for row in reader:
        centroid_rows.append(row)

if not centroid_rows:
    raise SystemExit("ERROR: centroids CSV has no rows")

# Determine centroid taxa columns:
ignore_cols = {"sampleID", "read_count", "sub_CST", "subCST"}
centroid_taxa_cols = [c for c in centroid_rows[0].keys() if c not in ignore_cols]

# Normalize centroid vectors (assumed already relative abundances)
centroids = {}  # sub_CST -> [abundances aligned to centroid_taxa_cols]
for row in centroid_rows:
    label = (row.get("sub_CST") or row.get("subCST") or "").strip()
    if not label:
        continue
    vec = []
    for c in centroid_taxa_cols:
        try:
            vec.append(float(row.get(c, 0) or 0))
        except Exception:
            vec.append(0.0)
    centroids[label] = vec

# Similarity function (Yue & Clayton-style from Valencia.py logic)
def yue_similarity(obs_vec, med_vec):
    product = 0.0
    diff_sq = 0.0
    for o, m in zip(obs_vec, med_vec):
        product += (m * o)
        d = (m - o)
        diff_sq += (d * d)
    denom = diff_sq + product
    return (product / denom) if denom != 0 else 0.0

# CST ordering (as in your previous embedded code)
CSTs = ['I-A','I-B','II','III-A','III-B','IV-A','IV-B','IV-C0','IV-C1','IV-C2','IV-C3','IV-C4','V']

# Load taxon table we just wrote and compute relative abundance vectors aligned to centroid taxa cols
samples = []
with open(taxon_table_csv, "r", encoding="utf-8", newline="") as f:
    reader = csv.DictReader(f)
    cols = reader.fieldnames or []
    if len(cols) < 3 or cols[0:2] != ["sampleID","read_count"]:
        raise SystemExit("ERROR: VALENCIA input expected first two headers: sampleID,read_count")
    taxa_cols_input = cols[2:]
    for row in reader:
        sid = (row.get("sampleID") or "").strip()
        rc = 0
        try:
            rc = int(float(row.get("read_count") or 0))
        except Exception:
            rc = 0
        taxa_counts = {t: float(row.get(t, 0) or 0) for t in taxa_cols_input}
        samples.append((sid, rc, taxa_counts))

# Build output rows with similarity columns
out_rows = []
for sid, rc, taxa_counts in samples:
    # relative abundance vector aligned to centroid_taxa_cols
    obs_vec = []
    if rc > 0:
        for t in centroid_taxa_cols:
            obs_vec.append(float(taxa_counts.get(t, 0.0)) / float(rc))
    else:
        obs_vec = [0.0 for _ in centroid_taxa_cols]

    sims = {}
    for cst in CSTs:
        if cst in centroids:
            sims[cst] = yue_similarity(obs_vec, centroids[cst])
        else:
            sims[cst] = float("nan")

    # pick best
    best_cst = None
    best_score = -1.0
    for cst in CSTs:
        v = sims.get(cst)
        if v is None:
            continue
        if isinstance(v, float) and math.isnan(v):
            continue
        if v > best_score:
            best_score = v
            best_cst = cst

    subcst = best_cst or ""
    score = best_score if best_cst else float("nan")

    # collapse CST groups
    cst_group = subcst
    if subcst in ("I-A","I-B"):
        cst_group = "I"
    elif subcst in ("III-A","III-B"):
        cst_group = "III"
    elif subcst in ("IV-C0","IV-C1","IV-C2","IV-C3","IV-C4"):
        cst_group = "IV-C"

    out_row = {"sampleID": sid, "read_count": rc}
    # include taxa cols (same as input)
    for t in taxa_cols_input:
        try:
            out_row[t] = int(float(taxa_counts.get(t, 0) or 0))
        except Exception:
            out_row[t] = 0
    # similarity cols
    for cst in CSTs:
        out_row[f"{cst}_sim"] = sims.get(cst)
    out_row["subCST"] = subcst
    out_row["score"] = score
    out_row["CST"] = cst_group
    out_rows.append(out_row)

# Write output.csv (requested) and a compatibility copy (valencia_assignments.csv)
def write_output_csv(path):
    if not out_rows:
        raise SystemExit("ERROR: No VALENCIA output rows to write")
    # keep stable column ordering
    taxa_cols = taxa_cols_input
    sim_cols = [f"{c}_sim" for c in CSTs]
    fieldnames = ["sampleID","read_count", *taxa_cols, *sim_cols, "subCST","score","CST"]
    with open(path, "w", encoding="utf-8", newline="") as out:
        w = csv.DictWriter(out, fieldnames=fieldnames)
        w.writeheader()
        for r in out_rows:
            w.writerow(r)

out_csv = os.path.join(out_dir, "output.csv")
compat_csv = os.path.join(out_dir, "valencia_assignments.csv")
write_output_csv(out_csv)
write_output_csv(compat_csv)

# -----------------------------
# Simple plots (SVG): similarity bar chart per sample
# -----------------------------
def svg_barplot(sample_id: str, title: str, values: list, labels: list, out_path: str):
    w = 900
    h = 360
    pad_l = 90
    pad_r = 20
    pad_t = 40
    pad_b = 40
    inner_w = w - pad_l - pad_r
    inner_h = h - pad_t - pad_b

    # sanitize values
    vals = []
    for v in values:
        if v is None:
            vals.append(0.0)
        elif isinstance(v, float) and math.isnan(v):
            vals.append(0.0)
        else:
            try:
                vals.append(float(v))
            except Exception:
                vals.append(0.0)

    max_v = max(vals) if vals else 1.0
    max_v = max(max_v, 1e-9)

    n = len(vals)
    if n == 0:
        return

    bar_gap = 6
    bar_w = max(2, int((inner_w - (n-1)*bar_gap) / n))

    # Build SVG
    esc = lambda s: (s or "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")
    parts = []
    parts.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">')
    parts.append(f'<rect x="0" y="0" width="{w}" height="{h}" fill="white"/>')
    parts.append(f'<text x="{pad_l}" y="24" font-family="Arial" font-size="16" fill="black">{esc(title)}</text>')
    # axes baseline
    parts.append(f'<line x1="{pad_l}" y1="{pad_t+inner_h}" x2="{pad_l+inner_w}" y2="{pad_t+inner_h}" stroke="black" stroke-width="1"/>')

    # bars
    x = pad_l
    for i, (lab, v) in enumerate(zip(labels, vals)):
        bh = int((v / max_v) * (inner_h))
        y = pad_t + inner_h - bh
        parts.append(f'<rect x="{x}" y="{y}" width="{bar_w}" height="{bh}" fill="#444"/>')
        # x labels (small)
        lx = x + bar_w/2
        parts.append(f'<text x="{lx}" y="{pad_t+inner_h+14}" font-family="Arial" font-size="10" fill="black" text-anchor="middle">{esc(lab)}</text>')
        x += bar_w + bar_gap

    # y label max
    parts.append(f'<text x="{pad_l}" y="{pad_t+inner_h+28}" font-family="Arial" font-size="10" fill="black">0</text>')
    parts.append(f'<text x="{pad_l}" y="{pad_t+10}" font-family="Arial" font-size="10" fill="black">{max_v:.3f}</text>')

    parts.append('</svg>')
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))

for r in out_rows:
    sid = r.get("sampleID","")
    sims = []
    for cst in CSTs:
        sims.append(r.get(f"{cst}_sim"))
    title = f"VALENCIA similarities for {sid} (subCST={r.get('subCST','')}, CST={r.get('CST','')})"
    out_path = os.path.join(plots_dir, f"{sid}_valencia_similarity.svg")
    svg_barplot(sid, title, sims, CSTs, out_path)

print(f"OK: VALENCIA input -> {taxon_table_csv}")
print(f"OK: VALENCIA taxa key -> {asv_taxa_csv}")
print(f"OK: VALENCIA output -> {out_csv}")
print(f"OK: VALENCIA plots -> {plots_dir}")
PY
    ec=$?
    set -e
    ended="$(iso_now)"

    if [[ $ec -ne 0 ]]; then
      steps_append "${STEPS_JSON}" "valencia" "failed" "VALENCIA classification failed (see logs/valencia.log)" "docker" "python3 (VALENCIA)" "${ec}" "${started}" "${ended}"
      exit 3
    else
      steps_append "${STEPS_JSON}" "valencia" "succeeded" "VALENCIA produced input CSV, output.csv, and plots" "docker" "python3 (VALENCIA)" "0" "${started}" "${ended}"

      tmp="${OUTPUTS_JSON}.tmp"
      jq --arg valencia_dir "${VALENCIA_DIR}" \
         --arg valencia_log "${VALENCIA_LOG}" \
         --arg valencia_centroids_csv "${STAGED_VALENCIA_CENTROIDS}" \
         --arg valencia_input_csv "${VALENCIA_INPUT_CSV}" \
         --arg valencia_asv_taxa_csv "${VALENCIA_ASV_TAXA_CSV}" \
         --arg valencia_output_csv "${VALENCIA_OUTPUT_CSV}" \
         --arg valencia_assignments_csv "${VALENCIA_ASSIGNMENTS_CSV}" \
         --arg valencia_plots_dir "${VALENCIA_PLOTS_DIR}" \
         '. + {
            valencia: {
              dir: $valencia_dir,
              log: $valencia_log,
              centroids_csv: ($valencia_centroids_csv | select(length>0) // null),
              valencia_input_csv: ($valencia_input_csv | select(length>0) // null),
              asv_condensed_taxa_names_csv: ($valencia_asv_taxa_csv | select(length>0) // null),
              output_csv: ($valencia_output_csv | select(length>0) // null),
              assignments_csv: ($valencia_assignments_csv | select(length>0) // null),
              plots_dir: ($valencia_plots_dir | select(length>0) // null)
            }
          }' "${OUTPUTS_JSON}" > "${tmp}"
      mv "${tmp}" "${OUTPUTS_JSON}"
    fi
  fi

  echo "[${MODULE_NAME}] Done"
  print_step_status "${STEPS_JSON}" "fastqc"
  print_step_status "${STEPS_JSON}" "multiqc"
  print_step_status "${STEPS_JSON}" "metadata_normalize"
  print_step_status "${STEPS_JSON}" "metadata_validate"
  print_step_status "${STEPS_JSON}" "qiime2_import"
  print_step_status "${STEPS_JSON}" "qiime2_demux_summarize"
  print_step_status "${STEPS_JSON}" "qiime2_cutadapt"
  print_step_status "${STEPS_JSON}" "qiime2_dada2"
  print_step_status "${STEPS_JSON}" "qiime2_taxonomy"
  print_step_status "${STEPS_JSON}" "qiime2_diversity_alpha"
  print_step_status "${STEPS_JSON}" "qiime2_diversity_core"
  print_step_status "${STEPS_JSON}" "qiime2_exports"
  print_step_status "${STEPS_JSON}" "valencia"
  echo "[${MODULE_NAME}] outputs.json: ${OUTPUTS_JSON}"
fi
