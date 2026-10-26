#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run_postprocess.sh --sweep-root <DIR> --run-base <NAME> [options]

What it does (sweep-level):
  - Finds param dirs: <run_base>_<num>param under <sweep-root>
  - Copies QIIME2 alpha-diversity exports from each run into:
      <param_dir>/diversity/<metric>_export/alpha-diversity.tsv
    (so alpha_diversity_sweep_plot.R can read them)
  - Copies VALENCIA output.csv from each run into:
      <sweep-root>/postprocess/valencia/<run_base>_<num>param_valencia_out.csv
  - Runs:
      valencia_cst_collate.py
      plot_valencia_cst_sweep.R
      alpha_diversity_sweep_plot.R
    using docker for R (rocker/tidyverse)

Required:
  - python3
Optional:
  - docker (needed for the R plots)

Options:
  --r-image <IMAGE>         R docker image to use (default: rocker/tidyverse:latest)
  --metrics <CSV>           Alpha metrics (default: shannon,observed_features,pielou_e)
  --alpha-out-name <NAME>   out_name arg for alpha script (default: alpha)
  --dry-run                 Print actions without changing files
  -h, --help                Show help

Example:
  bash main/pipelines/postprocess/run_postprocess.sh \
    --sweep-root "/path/to/main/runs" \
    --run-base "vaginal_testrun"

EOF
}

SWEEP_ROOT=""
RUN_BASE=""
R_IMAGE="rocker/tidyverse:latest"
METRICS="shannon,observed_features,pielou_e"
ALPHA_OUT_NAME="alpha"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sweep-root) SWEEP_ROOT="${2:-}"; shift 2 ;;
    --run-base) RUN_BASE="${2:-}"; shift 2 ;;
    --r-image) R_IMAGE="${2:-}"; shift 2 ;;
    --metrics) METRICS="${2:-}"; shift 2 ;;
    --alpha-out-name) ALPHA_OUT_NAME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${SWEEP_ROOT}" || -z "${RUN_BASE}" ]]; then
  echo "ERROR: --sweep-root and --run-base are required" >&2
  usage
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not found in PATH" >&2
  exit 2
fi

SWEEP_ROOT="$(python3 - "${SWEEP_ROOT}" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"

if [[ ! -d "${SWEEP_ROOT}" ]]; then
  echo "ERROR: sweep root not found: ${SWEEP_ROOT}" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALPHA_R="${SCRIPT_DIR}/alpha_diversity_sweep_plot.R"
VAL_PLOT_R="${SCRIPT_DIR}/plot_valencia_cst_sweep.R"
VAL_COLLATE_PY="${SCRIPT_DIR}/valencia_cst_collate.py"

if [[ ! -f "${ALPHA_R}" ]]; then
  echo "ERROR: Missing ${ALPHA_R}" >&2
  exit 2
fi
if [[ ! -f "${VAL_PLOT_R}" ]]; then
  echo "ERROR: Missing ${VAL_PLOT_R}" >&2
  exit 2
fi
if [[ ! -f "${VAL_COLLATE_PY}" ]]; then
  echo "ERROR: Missing ${VAL_COLLATE_PY}" >&2
  exit 2
fi

POSTPROC_ROOT="${SWEEP_ROOT}/postprocess"
POSTPROC_LOGS="${POSTPROC_ROOT}/logs"
POSTPROC_DIVERSITY="${POSTPROC_ROOT}/diversity"
POSTPROC_VALENCIA="${POSTPROC_ROOT}/valencia"

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

mkdir -p "${POSTPROC_LOGS}" "${POSTPROC_DIVERSITY}" "${POSTPROC_VALENCIA}"

# Find param dirs under sweep root
mapfile -t PARAM_DIRS < <(python3 - "${SWEEP_ROOT}" "${RUN_BASE}" <<'PY'
import os, re, sys
root, base = sys.argv[1], sys.argv[2]
pat = re.compile(rf'^{re.escape(base)}_(\d+(?:\.\d+)?)param$')
hits = []
for name in os.listdir(root):
    p = os.path.join(root, name)
    if not os.path.isdir(p):
        continue
    if pat.match(name):
        hits.append(name)
def num_key(n):
    m = pat.match(n)
    v = float(m.group(1)) if m else 999999.0
    return (v, n)
hits.sort(key=num_key)
for h in hits:
    print(os.path.join(root, h))
PY
)

if [[ ${#PARAM_DIRS[@]} -lt 1 ]]; then
  echo "No param directories found under: ${SWEEP_ROOT}"
  echo "Expected folders like: ${RUN_BASE}_0.26param"
  exit 0
fi

echo "Found ${#PARAM_DIRS[@]} param directory(ies)."
for d in "${PARAM_DIRS[@]}"; do
  echo "  - $(basename "${d}")"
done

# Helper: parse param from dir name
dir_param() {
  python3 - "$1" "$RUN_BASE" <<'PY'
import re, sys, os
p = os.path.basename(sys.argv[1])
base = sys.argv[2]
m = re.match(rf'^{re.escape(base)}_(\d+(?:\.\d+)?)param$', p)
print(m.group(1) if m else "")
PY
}

# Copy alpha diversity exports into the layout the R script expects
# Source layout (your pipeline):
#   <param_dir>/sr_amp/results/qiime2/diversity/alpha/<metric>_export/alpha-diversity.tsv
# Dest layout (for the R script):
#   <param_dir>/diversity/<metric>_export/alpha-diversity.tsv
IFS=',' read -r -a METRIC_ARR <<<"${METRICS}"

alpha_copied=0
valencia_copied=0

for PARAM_DIR in "${PARAM_DIRS[@]}"; do
  pval="$(dir_param "${PARAM_DIR}")"
  [[ -n "${pval}" ]] || continue

  # alpha copies
  for m in "${METRIC_ARR[@]}"; do
    m="$(echo "${m}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [[ -n "${m}" ]] || continue

    src="${PARAM_DIR}/sr_amp/results/qiime2/diversity/alpha/${m}_export/alpha-diversity.tsv"
    dst_dir="${PARAM_DIR}/diversity/${m}_export"
    dst="${dst_dir}/alpha-diversity.tsv"

    if [[ -f "${src}" ]]; then
      run_cmd "mkdir -p \"${dst_dir}\""
      run_cmd "cp -f \"${src}\" \"${dst}\""
      alpha_copied=$((alpha_copied + 1))
    fi
  done

  # valencia output copy into shared sweep folder
  src_val="${PARAM_DIR}/sr_amp/results/valencia/output.csv"
  if [[ -f "${src_val}" ]]; then
    out_name="${RUN_BASE}_${pval}param_valencia_out.csv"
    run_cmd "cp -f \"${src_val}\" \"${POSTPROC_VALENCIA}/${out_name}\""
    valencia_copied=$((valencia_copied + 1))
  fi
done

echo "Alpha diversity files copied: ${alpha_copied}"
echo "VALENCIA outputs copied: ${valencia_copied}"

# Build a clean diversity root for the R script via symlinks (so plots land in postprocess/diversity)
# It expects: <div_root>/<run_base>_<num>param/...
# We'll symlink each param dir into postprocess/diversity/
for PARAM_DIR in "${PARAM_DIRS[@]}"; do
  bn="$(basename "${PARAM_DIR}")"
  link="${POSTPROC_DIVERSITY}/${bn}"

  # relative target from postprocess/diversity -> sweep root is ../../
  rel_target="$(python3 - "${POSTPROC_DIVERSITY}" "${PARAM_DIR}" <<'PY'
import os, sys
src_dir = sys.argv[1]
target = sys.argv[2]
print(os.path.relpath(target, start=src_dir))
PY
)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] ln -sfn \"${rel_target}\" \"${link}\""
  else
    rm -f "${link}" || true
    ln -s "${rel_target}" "${link}" 2>/dev/null || true
  fi
done

# Run VALENCIA collation (python) if we have >=1 copied file
VAL_COLLATE_LOG="${POSTPROC_LOGS}/${RUN_BASE}_valencia_collate.log"
VAL_PLOT_LOG="${POSTPROC_LOGS}/${RUN_BASE}_valencia_plot.log"
ALPHA_LOG="${POSTPROC_LOGS}/${RUN_BASE}_alpha_diversity_sweep.log"

if [[ ${valencia_copied} -gt 0 ]]; then
  echo "Running VALENCIA CST collation..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[dry-run] python3 \"${VAL_COLLATE_PY}\" \"${POSTPROC_VALENCIA}\" \"${RUN_BASE}\" >\"${VAL_COLLATE_LOG}\" 2>&1"
  else
    python3 "${VAL_COLLATE_PY}" "${POSTPROC_VALENCIA}" "${RUN_BASE}" >"${VAL_COLLATE_LOG}" 2>&1 || {
      echo "ERROR: VALENCIA collation failed. See: ${VAL_COLLATE_LOG}" >&2
      exit 3
    }
  fi

  if command -v docker >/dev/null 2>&1; then
    echo "Running VALENCIA sweep plotting (R via docker: ${R_IMAGE})..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] docker run --rm --platform=linux/amd64 -v \"${POSTPROC_VALENCIA}:/data:rw\" -v \"${SCRIPT_DIR}:/scripts:ro\" \"${R_IMAGE}\" Rscript /scripts/plot_valencia_cst_sweep.R /data \"${RUN_BASE}\" >\"${VAL_PLOT_LOG}\" 2>&1"
    else
      docker run --rm --platform=linux/amd64 \
        -v "${POSTPROC_VALENCIA}:/data:rw" \
        -v "${SCRIPT_DIR}:/scripts:ro" \
        "${R_IMAGE}" \
        Rscript /scripts/plot_valencia_cst_sweep.R /data "${RUN_BASE}" >"${VAL_PLOT_LOG}" 2>&1 || {
          echo "ERROR: VALENCIA plotting failed. See: ${VAL_PLOT_LOG}" >&2
          exit 3
        }
    fi
  else
    echo "NOTE: docker not found; skipping VALENCIA R plots."
  fi
else
  echo "No VALENCIA outputs found to collate; skipping VALENCIA postprocess."
fi

# Run alpha diversity sweep plots if we copied anything and have >=2 params (sweep)
if [[ ${#PARAM_DIRS[@]} -ge 2 && ${alpha_copied} -gt 0 ]]; then
  if command -v docker >/dev/null 2>&1; then
    echo "Running alpha diversity sweep plots (R via docker: ${R_IMAGE})..."
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "[dry-run] docker run --rm --platform=linux/amd64 -v \"${POSTPROC_DIVERSITY}:/data:rw\" -v \"${SCRIPT_DIR}:/scripts:ro\" \"${R_IMAGE}\" Rscript /scripts/alpha_diversity_sweep_plot.R /data \"${RUN_BASE}\" \"${METRICS}\" \"${ALPHA_OUT_NAME}\" >\"${ALPHA_LOG}\" 2>&1"
    else
      docker run --rm --platform=linux/amd64 \
        -v "${POSTPROC_DIVERSITY}:/data:rw" \
        -v "${SCRIPT_DIR}:/scripts:ro" \
        "${R_IMAGE}" \
        Rscript /scripts/alpha_diversity_sweep_plot.R /data "${RUN_BASE}" "${METRICS}" "${ALPHA_OUT_NAME}" >"${ALPHA_LOG}" 2>&1 || {
          echo "ERROR: Alpha diversity plotting failed. See: ${ALPHA_LOG}" >&2
          exit 3
        }
    fi
  else
    echo "NOTE: docker not found; skipping alpha diversity R plots."
  fi
else
  echo "Skipping alpha diversity sweep plot (need >=2 param dirs and alpha exports present)."
fi

# Write a small manifest JSON for convenience
MANIFEST_JSON="${POSTPROC_ROOT}/outputs.json"
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "[dry-run] write ${MANIFEST_JSON}"
else
  python3 - "${MANIFEST_JSON}" "${SWEEP_ROOT}" "${RUN_BASE}" "${POSTPROC_ROOT}" "${POSTPROC_DIVERSITY}" "${POSTPROC_VALENCIA}" <<'PY'
import json, os, sys, glob
out_path, sweep_root, run_base, pp_root, div_root, val_root = sys.argv[1:]

def gl(pat):
    return sorted([os.path.realpath(x) for x in glob.glob(pat)])

manifest = {
  "sweep_root": sweep_root,
  "run_base": run_base,
  "postprocess_root": pp_root,
  "diversity": {
    "root": div_root,
    "logs": gl(os.path.join(pp_root, "logs", f"{run_base}_alpha_diversity_sweep.log")),
    "outputs": gl(os.path.join(div_root, f"{run_base}_*_diversity_long.csv")) +
               gl(os.path.join(div_root, f"{run_base}_*_*_sweep_*.png")) +
               gl(os.path.join(div_root, f"{run_base}_*_*_sweep_*.pdf"))
  },
  "valencia": {
    "root": val_root,
    "logs": gl(os.path.join(pp_root, "logs", f"{run_base}_valencia_*.log")),
    "inputs": gl(os.path.join(val_root, f"{run_base}_*param_valencia_out.csv")),
    "collate_outputs": gl(os.path.join(val_root, f"{run_base}_valencia_cst_*")),
    "plots": gl(os.path.join(val_root, f"{run_base}_valencia_cst_sweep_*.png")) +
             gl(os.path.join(val_root, f"{run_base}_valencia_cst_sweep_*.pdf"))
  }
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
print(f"Wrote manifest: {out_path}")
PY
fi

echo ""
echo "Postprocess complete."
echo "  Outputs: ${POSTPROC_ROOT}"
echo "  Logs:    ${POSTPROC_LOGS}"
echo "  Manifest:${MANIFEST_JSON}"
