#!/usr/bin/env bash
set -euo pipefail

MODULE_NAME="lr_meta"

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
if [[ ! -f "${TOOLS_SH}" ]]; then
  echo "ERROR: Missing shared tools file: ${TOOLS_SH}" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "${TOOLS_SH}"

############################################
##              COLOURS                   ##
############################################
BOLD="\033[1m"
RESET="\033[0m"
GREEN="\033[32m"
RED="\033[31m"
PURPLE="\033[35m"
CYAN="\033[36m"
YELLOW="\033[33m"

log() { echo -e "[$(date '+%F %T')] $*" >&2; }
log_info() { log "${CYAN}${BOLD}$*${RESET}"; }
log_warn() { log "${YELLOW}${BOLD}$*${RESET}"; }
log_ok() { log "${GREEN}${BOLD}$*${RESET}"; }
log_done() { log "${PURPLE}${BOLD}$*${RESET}"; }
log_fail() { log "${RED}${BOLD}$*${RESET}"; }

die() { log_fail "$*"; exit 1; }

on_error() {
  local lineno="$1"
  local cmd="$2"
  log_fail "FAILED at line ${lineno}: ${cmd}"
  log_fail "Pipeline stopped."
}
trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR

normalize_boolish() {
  local raw="${1:-}"
  local norm="false"
  if [[ -z "${raw}" || "${raw}" == "null" ]]; then
    echo "${norm}"; return 0
  fi
  case "$(printf "%s" "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1|true|yes|y|on) norm="true" ;;
    0|false|no|n|off) norm="false" ;;
    *) norm="false" ;;
  esac
  echo "${norm}"
}

############################################
##              HELPERS                   ##
############################################

jq_first() {
  local file="$1"; shift
  local v=""
  for expr in "$@"; do
    v="$(jq -er "${expr} // empty" "${file}" 2>/dev/null || true)"
    if [[ -n "${v}" && "${v}" != "null" ]]; then echo "${v}"; return 0; fi
  done
  return 1
}

require_file() {
  local p="$1"
  [[ -n "${p}" && "${p}" != "null" ]] || { echo "ERROR: Required file path is empty" >&2; exit 2; }
  [[ -f "${p}" ]] || { echo "ERROR: File not found: ${p}" >&2; exit 2; }
}

require_dir() {
  local p="$1"
  [[ -n "${p}" && "${p}" != "null" ]] || { echo "ERROR: Required directory path is empty" >&2; exit 2; }
  [[ -d "${p}" ]] || { echo "ERROR: Directory not found: ${p}" >&2; exit 2; }
}

resolve_fastq_single() {
  local p="$1"
  [[ -n "${p}" && "${p}" != "null" ]] || { echo ""; return 0; }
  if [[ -f "${p}" ]]; then echo "${p}"; return 0; fi
  if [[ -d "${p}" ]]; then
    local found=""
    found="$(find "${p}" -maxdepth 1 -type f \( -iname "*.fastq" -o -iname "*.fq" -o -iname "*.fastq.gz" -o -iname "*.fq.gz" \) | sort | head -n 1 || true)"
    [[ -n "${found}" ]] && { echo "${found}"; return 0; }
  fi
  echo ""
}

# Resolve FASTQ input(s) to a newline-separated list of file paths.
# Handles:
#   - Single file path (string)
#   - Directory path (finds all FASTQs within, non-recursive)
#   - Glob pattern (e.g., "/path/*.fastq")
#   - JSON array of paths
# Returns paths via stdout, one per line.
resolve_fastq_list() {
  local config_path="$1"
  local resolved=()

  # Try to get .input.fastq value - could be string or array
  local fastq_val
  fastq_val="$(jq -r '.input.fastq // .inputs.fastq // empty' "${config_path}" 2>/dev/null || true)"

  # Also check .input.fastqs as an array alias
  local fastqs_val
  fastqs_val="$(jq -r '.input.fastqs // .inputs.fastqs // empty' "${config_path}" 2>/dev/null || true)"

  # Check if .input.fastq is an array
  local is_array
  is_array="$(jq -r 'if (.input.fastq // .inputs.fastq) | type == "array" then "yes" else "no" end' "${config_path}" 2>/dev/null || echo "no")"

  if [[ "${is_array}" == "yes" ]]; then
    # Parse JSON array of paths
    while IFS= read -r path; do
      [[ -n "${path}" && "${path}" != "null" ]] || continue
      resolved+=("${path}")
    done < <(jq -r '(.input.fastq // .inputs.fastq) | .[]' "${config_path}" 2>/dev/null)
  elif [[ -n "${fastq_val}" && "${fastq_val}" != "null" ]]; then
    # Single string value - could be file, directory, or glob
    resolved+=("${fastq_val}")
  fi

  # Also process .input.fastqs array if present
  local is_fastqs_array
  is_fastqs_array="$(jq -r 'if (.input.fastqs // .inputs.fastqs) | type == "array" then "yes" else "no" end' "${config_path}" 2>/dev/null || echo "no")"

  if [[ "${is_fastqs_array}" == "yes" ]]; then
    while IFS= read -r path; do
      [[ -n "${path}" && "${path}" != "null" ]] || continue
      resolved+=("${path}")
    done < <(jq -r '(.input.fastqs // .inputs.fastqs) | .[]' "${config_path}" 2>/dev/null)
  elif [[ -n "${fastqs_val}" && "${fastqs_val}" != "null" ]]; then
    resolved+=("${fastqs_val}")
  fi

  # Now expand each entry (file, directory, or glob) to actual files
  local final_files=()
  for entry in "${resolved[@]}"; do
    [[ -n "${entry}" ]] || continue

    if [[ -f "${entry}" ]]; then
      # Direct file
      final_files+=("${entry}")
    elif [[ -d "${entry}" ]]; then
      # Directory - find all FASTQs (non-recursive)
      while IFS= read -r f; do
        [[ -n "${f}" ]] && final_files+=("${f}")
      done < <(find "${entry}" -maxdepth 1 -type f \( -iname "*.fastq" -o -iname "*.fq" -o -iname "*.fastq.gz" -o -iname "*.fq.gz" \) | sort)
    elif [[ "${entry}" == *"*"* || "${entry}" == *"?"* || "${entry}" == *"["* ]]; then
      # Glob pattern - expand it
      shopt -s nullglob
      local expanded=( ${entry} )
      shopt -u nullglob
      for f in "${expanded[@]}"; do
        [[ -f "${f}" ]] && final_files+=("${f}")
      done
    else
      # Try as a file that might not exist yet (container path resolution)
      # Just add it; validation will catch missing files later
      final_files+=("${entry}")
    fi
  done

  # Output unique files, one per line
  printf '%s\n' "${final_files[@]}" | sort -u
}

count_fastq_lines() {
  local p="$1"
  require_file "${p}"
  if [[ "${p}" == *.gz ]]; then gzip -cd "${p}" | wc -l | tr -d ' '; else wc -l < "${p}" | tr -d ' '; fi
}

estimate_reads_from_lines() {
  local lines="$1"
  python3 - "$lines" <<'PY'
import sys
lines = int(sys.argv[1])
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

exit_code_means_tool_missing() {
  # keep consistent with other modules if tools.sh provides this; fallback if not
  if command -v exit_code_means_tool_missing >/dev/null 2>&1; then
    exit_code_means_tool_missing "$@"
    return $?
  fi
  local ec="${1:-0}"
  [[ "$ec" -eq 127 ]]
}

check_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
make_dir() { [[ -d "$1" ]] || { log_info "Creating: $1"; mkdir -p "$1"; }; }

run_step() {
  local steps_path="$1"
  local step_name="$2"
  local title="$3"
  shift 3
  local started ended ec tool cmd msg status

  started="$(iso_now)"
  tool="${1:-}"
  cmd="$*"

  log_info "$title"
  set +e
  "$@"
  ec=$?
  set -e
  ended="$(iso_now)"

  if [[ $ec -eq 0 ]]; then
    status="succeeded"
    msg="${title} completed"
    steps_append "${steps_path}" "${step_name}" "${status}" "${msg}" "${tool}" "${cmd}" "${ec}" "${started}" "${ended}"
    log_ok "$title - PASSED"
    return 0
  fi

  if exit_code_means_tool_missing "${ec}"; then
    status="skipped"
    msg="${title} skipped (tool missing at runtime)"
    steps_append "${steps_path}" "${step_name}" "${status}" "${msg}" "${tool}" "${cmd}" "${ec}" "${started}" "${ended}"
    log_warn "$title - SKIPPED (tool missing)"
    return 0
  fi

  status="failed"
  msg="${title} failed"
  steps_append "${steps_path}" "${step_name}" "${status}" "${msg}" "${tool}" "${cmd}" "${ec}" "${started}" "${ended}"
  log_fail "$title - FAILED (exit $ec)"
  return "$ec"
}

############################################
##               CONFIG                   ##
############################################

INPUT_STYLE="$(jq_first "${CONFIG_PATH}" '.input.style' '.inputs.style' '.input_style' '.inputs.input_style' || true)"
[[ -n "${INPUT_STYLE}" ]] || INPUT_STYLE="FASTQ_SINGLE"

# Read output directory - prefer run_dir (already includes {work_dir}/{run_id})
# to match behavior of sr_meta and sr_amp
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

if [[ -n "${PIPELINE_ID:-}" && "${PIPELINE_ID}" != "${MODULE_NAME}" ]]; then
  echo "ERROR: Config pipeline_id (${PIPELINE_ID}) does not match module (${MODULE_NAME})." >&2
  exit 2
fi

# Layout: <run_dir>/lr_meta/...
# Note: OUTPUT_DIR already includes {work_dir}/{run_id} when run via stamina_biome_run.sh
MODULE_OUT_DIR="${OUTPUT_DIR}/${MODULE_NAME}"
INPUTS_DIR="${MODULE_OUT_DIR}/inputs"
RESULTS_DIR="${MODULE_OUT_DIR}/results"
LOGS_DIR="${MODULE_OUT_DIR}/logs"
STEPS_JSON="${MODULE_OUT_DIR}/steps.json"
mkdir -p "${INPUTS_DIR}" "${RESULTS_DIR}" "${LOGS_DIR}"

# Reset steps.json at the start of each run (prevent accumulation from previous runs)
printf "[]\n" > "${STEPS_JSON}"

FASTQ_STAGE_DIR="${INPUTS_DIR}/fastq"
FAST5_STAGE_DIR="${INPUTS_DIR}/fast5"
POD5_STAGE_DIR="${INPUTS_DIR}/pod5"
BAM_STAGE_DIR="${INPUTS_DIR}/bam"
DEMUX_DIR="${RESULTS_DIR}/demux"
TRIM_DIR="${RESULTS_DIR}/trim"
RAW_READS_DIR="${RESULTS_DIR}/raw_reads"
RAW_FASTQC_DIR="${RESULTS_DIR}/raw_fastqc"
RAW_MULTIQC_DIR="${RESULTS_DIR}/raw_multiqc"
QFILTER_DIR="${RESULTS_DIR}/qfiltered"
INDEX_DIR="${RESULTS_DIR}/human_index"
ALN_DIR="${RESULTS_DIR}/human_align"
NONHUMAN_DIR="${RESULTS_DIR}/nonhuman"
TAXO_ROOT="${RESULTS_DIR}/taxonomy"
VALENCIA_TMP="${RESULTS_DIR}/valencia/tmp"
VALENCIA_RESULTS="${RESULTS_DIR}/valencia/results"

mkdir -p \
  "${FASTQ_STAGE_DIR}" "${FAST5_STAGE_DIR}" "${POD5_STAGE_DIR}" "${BAM_STAGE_DIR}" \
  "${DEMUX_DIR}" "${TRIM_DIR}" "${RAW_READS_DIR}" "${RAW_FASTQC_DIR}" "${RAW_MULTIQC_DIR}" \
  "${QFILTER_DIR}" "${INDEX_DIR}" "${ALN_DIR}" "${NONHUMAN_DIR}" "${TAXO_ROOT}" \
  "${VALENCIA_TMP}" "${VALENCIA_RESULTS}"

RUN_NAME_BASE="$(jq_first "${CONFIG_PATH}" '.run.run_name' '.run.name' '.run_name' '.id' '.run_id' || true)"
[[ -n "${RUN_NAME_BASE}" ]] || RUN_NAME_BASE="$(date +%Y%m%d_%H%M%S)"
RUN_NAME="${RUN_NAME_BASE}"

SAMPLE_SHEET="$(jq_first "${CONFIG_PATH}" '.inputs.sample_sheet' '.input.sample_sheet' '.sample_sheet' '.barcode_sites_tsv' || true)"

THREADS="$(jq_first "${CONFIG_PATH}" '.resources.threads' '.run.threads' '.threads' || true)"
[[ -n "${THREADS}" ]] || THREADS="8"
SAMTOOLS_THREADS="$(jq_first "${CONFIG_PATH}" '.resources.samtools_threads' '.run.samtools_threads' '.samtools_threads' || true)"
[[ -n "${SAMTOOLS_THREADS}" ]] || SAMTOOLS_THREADS="$THREADS"

QFILTER_ENABLED="$(jq_first "${CONFIG_PATH}" '.tools.qfilter.enabled' '.qfilter.enabled' '.qfilter_enabled' || true)"
[[ -n "${QFILTER_ENABLED}" ]] || QFILTER_ENABLED="0"
QFILTER_MIN_Q="$(jq_first "${CONFIG_PATH}" '.tools.qfilter.min_q' '.qfilter.min_q' '.qfilter_min_q' || true)"
[[ -n "${QFILTER_MIN_Q}" ]] || QFILTER_MIN_Q="10"

# VALENCIA config (mirroring sr_amp approach)
VALENCIA_ENABLED_RAW="$(jq_first "${CONFIG_PATH}" '.valencia.enabled' '.tools.valencia.enabled' '.valencia_enabled' || true)"
VALENCIA_CENTROIDS_CSV="$(jq_first "${CONFIG_PATH}" '.valencia.centroids_csv' '.tools.valencia.centroids_csv' || true)"
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

PY_SUMMARY_SCRIPT="$(jq_first "${CONFIG_PATH}" '.tools.summaries.python_script' '.python_summary_script' || true)"
R_PLOT_SCRIPT="$(jq_first "${CONFIG_PATH}" '.tools.summaries.r_script' '.r_plot_script' || true)"

# Postprocess settings (generate summary tables and plots from kraken2 results)
POSTPROCESS_ENABLED="$(jq_first "${CONFIG_PATH}" '.postprocess.enabled' '.tools.postprocess.enabled' '.postprocess_enabled' || true)"
[[ -n "${POSTPROCESS_ENABLED}" ]] || POSTPROCESS_ENABLED="1"

# Dorado/Pod5 settings (optional, only used when FAST5 input is provided)
DORADO_MODEL="$(jq_first "${CONFIG_PATH}" '.tools.dorado.model' '.dorado.model' || true)"
LIGATION_KIT="$(jq_first "${CONFIG_PATH}" '.tools.dorado.ligation_kit' '.dorado.ligation_kit' || true)"
BARCODE_KIT="$(jq_first "${CONFIG_PATH}" '.tools.dorado.barcode_kit' '.dorado.barcode_kit' || true)"
SEQUENCING_KIT="$(jq_first "${CONFIG_PATH}" '.tools.dorado.sequencing_kit' '.dorado.sequencing_kit' || true)"
PRIMER_FASTA="$(jq_first "${CONFIG_PATH}" '.tools.dorado.primer_fasta' '.dorado.primer_fasta' || true)"

# References + DB
GRCH38_FA="$(jq_first "${CONFIG_PATH}" '.refs.human_fa' '.tools.minimap2.human_fa' '.tools.host_depletion.human_fa' || true)"
# Pre-built minimap2 index (preferred over building from FA to save memory)
GRCH38_MMI="$(jq_first "${CONFIG_PATH}" '.refs.human_mmi' '.tools.minimap2.human_mmi' '.tools.host_depletion.human_mmi' || true)"
# Split-prefix mode for low-RAM machines (required when using multi-part/split minimap2 indices)
MINIMAP2_SPLIT_PREFIX="$(jq_first "${CONFIG_PATH}" '.tools.minimap2.split_prefix' '.tools.host_depletion.split_prefix' || true)"
[[ -n "${MINIMAP2_SPLIT_PREFIX}" ]] || MINIMAP2_SPLIT_PREFIX="0"

# Host depletion (minimap2) enable/disable — mirrors sr_meta behaviour
REMOVE_HOST_RAW="$(jq_first "${CONFIG_PATH}" \
  '.params.common.remove_host' \
  '.params.remove_host' \
  '.common.remove_host' \
  '.remove_host' \
  || true)"
REMOVE_HOST_NORM="$(normalize_boolish "${REMOVE_HOST_RAW}")"

# Configurable sample name for FASTQ_SINGLE / BAM-single-sample mode
# Defaults to the FASTQ filename stem; set input.sample_name in config to override
SINGLE_SAMPLE_NAME="$(jq_first "${CONFIG_PATH}" '.input.sample_name' '.run.sample_name' || true)"
[[ -n "${SINGLE_SAMPLE_NAME}" && "${SINGLE_SAMPLE_NAME}" != "null" ]] || SINGLE_SAMPLE_NAME=""

KRAKEN2_DB="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.db' '.tools.kraken2.db_classify' '.kraken2_db' || true)"

# Fixed kraken params
KRAKEN_CONF_VAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.vaginal.confidence' '.kraken_confidence_vaginal' || true)"
[[ -n "${KRAKEN_CONF_VAGINAL}" ]] || KRAKEN_CONF_VAGINAL="0.05"
KRAKEN_MHG_VAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.vaginal.minimum_hit_groups' '.kraken_min_hit_groups_vaginal' || true)"
[[ -n "${KRAKEN_MHG_VAGINAL}" ]] || KRAKEN_MHG_VAGINAL="2"

KRAKEN_CONF_NONVAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.nonvaginal.confidence' '.kraken_confidence_nonvaginal' || true)"
[[ -n "${KRAKEN_CONF_NONVAGINAL}" ]] || KRAKEN_CONF_NONVAGINAL="0.02"
KRAKEN_MHG_NONVAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.nonvaginal.minimum_hit_groups' '.kraken_min_hit_groups_nonvaginal' || true)"
[[ -n "${KRAKEN_MHG_NONVAGINAL}" ]] || KRAKEN_MHG_NONVAGINAL="2"

USE_BRACKEN_VAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.bracken.vaginal.enabled' '.use_bracken_vaginal' || true)"
[[ -n "${USE_BRACKEN_VAGINAL}" ]] || USE_BRACKEN_VAGINAL="1"
BRACKEN_READLEN_VAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.bracken.vaginal.readlen' '.bracken_readlen_vaginal' || true)"
[[ -n "${BRACKEN_READLEN_VAGINAL}" ]] || BRACKEN_READLEN_VAGINAL="1500"

USE_BRACKEN_NONVAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.bracken.nonvaginal.enabled' '.use_bracken_nonvaginal' || true)"
[[ -n "${USE_BRACKEN_NONVAGINAL}" ]] || USE_BRACKEN_NONVAGINAL="1"
BRACKEN_READLEN_NONVAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.bracken.nonvaginal.readlen' '.bracken_readlen_nonvaginal' || true)"
[[ -n "${BRACKEN_READLEN_NONVAGINAL}" ]] || BRACKEN_READLEN_NONVAGINAL="${BRACKEN_READLEN_VAGINAL}"
BRACKEN_AVAILABLE="1"

############################################
##   INPUT RESOLUTION + STAGING (existing) ##
############################################

STAGED_FASTQ=""
STAGED_FAST5_DIR=""

case "${INPUT_STYLE}" in
  FASTQ_SINGLE)
    # Long-read pipelines only support single-end FASTQ - no R1/R2 paired-end concept
    # Check for accidental R1/R2 usage and warn
    HAS_R1="$(jq -r '.input.fastq_r1 // .inputs.fastq_r1 // empty' "${CONFIG_PATH}" 2>/dev/null || true)"
    HAS_R2="$(jq -r '.input.fastq_r2 // .inputs.fastq_r2 // empty' "${CONFIG_PATH}" 2>/dev/null || true)"
    if [[ -n "${HAS_R1}" || -n "${HAS_R2}" ]]; then
      log_warn "Long-read pipeline detected R1/R2 FASTQ config keys. These are ignored."
      log_warn "Long-read sequencing produces single-end reads only. Using .input.fastq instead."
    fi

    # Resolve FASTQ input(s) - supports single file, array, glob pattern, or directory
    # Returns list of files, one per line
    FASTQ_LIST_RAW="$(resolve_fastq_list "${CONFIG_PATH}")"

    # Convert to array
    FASTQ_FILES=()
    while IFS= read -r fq_path; do
      [[ -n "${fq_path}" ]] && FASTQ_FILES+=("${fq_path}")
    done <<< "${FASTQ_LIST_RAW}"

    # Validate we have at least one FASTQ
    if [[ ${#FASTQ_FILES[@]} -eq 0 ]]; then
      echo "ERROR: FASTQ_SINGLE selected but could not resolve any FASTQ file(s) from config." >&2
      echo "       Accepted config keys:" >&2
      echo "         .input.fastq  - string (single file, directory, or glob) OR array of paths" >&2
      echo "         .input.fastqs - array of paths" >&2
      echo "" >&2
      echo "       Examples:" >&2
      echo "         \"input\": { \"fastq\": \"/path/to/file.fastq.gz\" }" >&2
      echo "         \"input\": { \"fastq\": \"/path/to/fastq_dir/\" }" >&2
      echo "         \"input\": { \"fastq\": \"/path/to/*.fastq\" }" >&2
      echo "         \"input\": { \"fastq\": [\"/path/a.fastq\", \"/path/b.fastq\"] }" >&2
      exit 2
    fi

    # Preflight: Print resolved FASTQ list and verify each exists
    log_info "Resolved ${#FASTQ_FILES[@]} FASTQ file(s) for processing:"
    MISSING_FILES=()
    for fq in "${FASTQ_FILES[@]}"; do
      if [[ -f "${fq}" ]]; then
        log_info "  [OK] ${fq}"
      else
        log_fail "  [MISSING] ${fq}"
        MISSING_FILES+=("${fq}")
      fi
    done

    if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
      echo "ERROR: ${#MISSING_FILES[@]} FASTQ file(s) not found:" >&2
      for mf in "${MISSING_FILES[@]}"; do
        echo "  - ${mf}" >&2
      done
      exit 2
    fi

    # Stage FASTQs into per-barcode structure for downstream processing
    # Each FASTQ becomes its own "barcode" - use filename (sans extension) as barcode ID
    log_info "Staging ${#FASTQ_FILES[@]} FASTQ(s) into per-barcode layout..."
    STAGED_FASTQS=()  # Array to track all staged files
    BARCODE_IDS=()    # Array of barcode IDs (for outputs.json)

    for fq in "${FASTQ_FILES[@]}"; do
      # Derive barcode ID from filename (e.g., "barcode05.fastq" -> "barcode05")
      basename_full="$(basename "${fq}")"
      barcode_id="${basename_full%.fastq.gz}"
      barcode_id="${barcode_id%.fastq}"
      barcode_id="${barcode_id%.fq.gz}"
      barcode_id="${barcode_id%.fq}"

      # Override with explicit sample name if configured and only one file
      if [[ -n "${SINGLE_SAMPLE_NAME}" && ${#FASTQ_FILES[@]} -eq 1 ]]; then
        barcode_id="${SINGLE_SAMPLE_NAME}"
      fi

      # Create per-barcode subdirectory
      barcode_dir="${RAW_READS_DIR}/${RUN_NAME}/${barcode_id}"
      make_dir "${barcode_dir}"

      # Symlink or copy the FASTQ (keep as-is, no compression)
      if [[ "${fq}" == *.gz ]]; then
        staged_path="${barcode_dir}/${barcode_id}.fastq.gz"
      else
        staged_path="${barcode_dir}/${barcode_id}.fastq"
      fi

      ln -sfn "$(realpath "${fq}")" "${staged_path}" 2>/dev/null || cp "${fq}" "${staged_path}"
      STAGED_FASTQS+=("${staged_path}")
      BARCODE_IDS+=("${barcode_id}")
    done

    # Set PER_BARCODE_FASTQ_ROOT for downstream processing
    PER_BARCODE_FASTQ_ROOT="${RAW_READS_DIR}/${RUN_NAME}"
    log_info "Staged ${#STAGED_FASTQS[@]} FASTQ(s) to: ${PER_BARCODE_FASTQ_ROOT}"

    # For backwards compatibility, set STAGED_FASTQ to first file
    STAGED_FASTQ="${STAGED_FASTQS[0]:-}"
    ;;
  FAST5_DIR|FAST5)
    FAST5_DIR_SRC="$(jq_first "${CONFIG_PATH}" '.input.fast5_dir' '.inputs.fast5_dir' '.input.fast5' '.inputs.fast5' '.fast5_dir' '.fast5' || true)"
    [[ -n "${FAST5_DIR_SRC}" ]] || { echo "ERROR: FAST5 selected but no fast5_dir found in config" >&2; exit 2; }
    # Convert to absolute path for symlink (needed for container execution)
    if [[ "${FAST5_DIR_SRC}" != /* ]]; then
      FAST5_DIR_SRC="$(cd "$(dirname "${FAST5_DIR_SRC}")" && pwd)/$(basename "${FAST5_DIR_SRC}")"
    fi
    require_dir "${FAST5_DIR_SRC}"
    STAGED_FAST5_DIR="${FAST5_STAGE_DIR}/fast5"
    ln -sfn "${FAST5_DIR_SRC}" "${STAGED_FAST5_DIR}"
    ;;
  BAM)
    # BAM input - basecalled reads, skip basecalling step
    BAM_INPUT="$(jq_first "${CONFIG_PATH}" '.input.bam' '.inputs.bam' '.bam' || true)"
    [[ -n "${BAM_INPUT}" ]] || { echo "ERROR: BAM input style selected but no BAM file found in config" >&2; exit 2; }
    # Convert to absolute path
    if [[ "${BAM_INPUT}" != /* ]]; then
      BAM_INPUT="$(cd "$(dirname "${BAM_INPUT}")" && pwd)/$(basename "${BAM_INPUT}")"
    fi
    [[ -f "${BAM_INPUT}" ]] || { echo "ERROR: BAM file not found: ${BAM_INPUT}" >&2; exit 2; }
    # Stage BAM file for processing
    STAGED_BAM="${BAM_STAGE_DIR}/$(basename "${BAM_INPUT}")"
    make_dir "${BAM_STAGE_DIR}"
    ln -sfn "${BAM_INPUT}" "${STAGED_BAM}" 2>/dev/null || cp "${BAM_INPUT}" "${STAGED_BAM}"
    log_info "Staged BAM input: ${STAGED_BAM}"
    ;;
  *)
    echo "ERROR: Unsupported input style: ${INPUT_STYLE}. lr_meta supports FASTQ_SINGLE, FAST5_DIR, or BAM." >&2
    exit 2
    ;;
esac

OUTPUTS_JSON="${MODULE_OUT_DIR}/outputs.json"

# Build outputs.json with support for multiple FASTQs
if [[ "${INPUT_STYLE}" == "FASTQ_SINGLE" ]]; then
  # Build JSON array of staged FASTQs and barcode IDs
  FASTQS_JSON="[]"
  BARCODES_JSON="[]"
  for i in "${!STAGED_FASTQS[@]}"; do
    FASTQS_JSON="$(echo "${FASTQS_JSON}" | jq --arg fq "${STAGED_FASTQS[$i]}" '. + [$fq]')"
    BARCODES_JSON="$(echo "${BARCODES_JSON}" | jq --arg bc "${BARCODE_IDS[$i]}" '. + [$bc]')"
  done

  jq -n \
    --arg module_name "${MODULE_NAME}" \
    --arg pipeline_id "${PIPELINE_ID:-}" \
    --arg run_id "${RUN_ID:-}" \
    --arg input_style "${INPUT_STYLE}" \
    --arg fastq "${STAGED_FASTQ}" \
    --arg per_barcode_root "${PER_BARCODE_FASTQ_ROOT}" \
    --argjson fastq_list "${FASTQS_JSON}" \
    --argjson barcode_ids "${BARCODES_JSON}" \
    '{
      "module": $module_name,
      "pipeline_id": $pipeline_id,
      "run_id": $run_id,
      "run_name": "'"${RUN_NAME}"'",
      "input_style": $input_style,
      "inputs": {
        "fastq": $fastq,
        "fastq_list": $fastq_list,
        "barcode_ids": $barcode_ids,
        "per_barcode_root": $per_barcode_root,
        "sample_count": ($fastq_list | length)
      }
    }' > "${OUTPUTS_JSON}"
else
  jq -n \
    --arg module_name "${MODULE_NAME}" \
    --arg pipeline_id "${PIPELINE_ID:-}" \
    --arg run_id "${RUN_ID:-}" \
    --arg input_style "${INPUT_STYLE}" \
    --arg fast5_dir "${STAGED_FAST5_DIR}" \
    '{
      "module": $module_name,
      "pipeline_id": $pipeline_id,
      "run_id": $run_id,
      "run_name": "'"${RUN_NAME}"'",
      "input_style": $input_style,
      "inputs": { "fast5_dir": $fast5_dir }
    }' > "${OUTPUTS_JSON}"
fi

############################################
##              METRICS (existing)        ##
############################################
METRICS_JSON="${MODULE_OUT_DIR}/metrics.json"
if [[ "${INPUT_STYLE}" == "FASTQ_SINGLE" ]]; then
  # Calculate metrics for all FASTQs
  TOTAL_LINES=0
  TOTAL_READS=0
  SAMPLE_METRICS="[]"

  for i in "${!STAGED_FASTQS[@]}"; do
    staged="${STAGED_FASTQS[$i]}"
    barcode="${BARCODE_IDS[$i]}"
    if [[ -f "${staged}" ]]; then
      lines="$(count_fastq_lines "${staged}")"
      reads="$(estimate_reads_from_lines "${lines}")"
      TOTAL_LINES=$((TOTAL_LINES + lines))
      TOTAL_READS=$((TOTAL_READS + reads))
      SAMPLE_METRICS="$(echo "${SAMPLE_METRICS}" | jq \
        --arg barcode "${barcode}" \
        --arg fastq "${staged}" \
        --argjson lines "${lines}" \
        --argjson reads "${reads}" \
        '. + [{"barcode": $barcode, "fastq": $fastq, "fastq_lines": $lines, "reads_estimate": $reads}]')"
    fi
  done

  jq -n \
    --arg module_name "${MODULE_NAME}" \
    --argjson total_lines "${TOTAL_LINES}" \
    --argjson total_reads "${TOTAL_READS}" \
    --argjson sample_count "${#STAGED_FASTQS[@]}" \
    --argjson samples "${SAMPLE_METRICS}" \
    '{
      "module": $module_name,
      "sample_count": $sample_count,
      "total_fastq_lines": $total_lines,
      "total_reads_estimate": $total_reads,
      "samples": $samples
    }' > "${METRICS_JSON}"
else
  jq -n \
    --arg module_name "${MODULE_NAME}" \
    --arg note "metrics skipped (input_style is not FASTQ_SINGLE)" \
    '{ "module": $module_name, "note": $note }' > "${METRICS_JSON}"
fi

tmp="${OUTPUTS_JSON}.tmp"
jq --arg metrics_path "${METRICS_JSON}" --slurpfile metrics "${METRICS_JSON}" \
  '. + {"metrics_path":$metrics_path, "metrics":$metrics[0]}' "${OUTPUTS_JSON}" > "${tmp}"
mv "${tmp}" "${OUTPUTS_JSON}"

############################################
##     TOOL RESOLUTION (config-aware)     ##
############################################

# Prefer tools.sh resolve_tool where available; fall back to PATH.
POD5_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.pod5_bin' 'pod5')"
DORADO_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.dorado_bin' 'dorado')"
MINIMAP2_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.minimap2_bin' 'minimap2')"
SAMTOOLS_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.samtools_bin' 'samtools')"
FASTQC_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.fastqc_bin' 'fastqc')"
MULTIQC_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.multiqc_bin' 'multiqc')"
NANOFILT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.nanofilt_bin' 'NanoFilt')"
KRAKEN2_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.kraken2.bin' 'kraken2')"
KREPORT2KRONA_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.kreport2krona_bin' 'kreport2krona.py')"
KTIMPORT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.ktimport_bin' 'ktImportText')"
BRACKEN_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.bracken.bin' 'bracken')"
GIT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.git_bin' 'git')"
RSCRIPT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.rscript_bin' 'Rscript')"

############################################
##     OPTIONAL DORADO BASECALLING FLOW   ##
############################################
# Behavior:
# - If INPUT_STYLE is FAST5/FAST5_DIR: run POD5->basecall->demux->trim->bam2fq per barcode
# - If INPUT_STYLE is FASTQ_SINGLE: bypass basecalling and treat provided fastq as the analysis fastq (no demux).
# Note: FASTQ_SINGLE provides a single file; sample ID is derived from the filename (or input.sample_name in config).

PER_BARCODE_FASTQ_ROOT=""       # directory containing per-barcode fastqs (plain .fastq or .fastq.gz)
ANALYSIS_FASTQ_MODE="per_barcode"
NONHUMAN_RUN_DIR=""

ensure_metatax_tools() {
  # If user relies on conda in-container, keep it simple here: just check presence.
  # These commands must exist in PATH (container should provide them).
  check_cmd "${KRAKEN2_BIN}"
  check_cmd "${KREPORT2KRONA_BIN}"
  check_cmd "${KTIMPORT_BIN}"
}

check_bracken_available() {
  if ! command -v "${BRACKEN_BIN}" >/dev/null 2>&1; then
    BRACKEN_AVAILABLE="0"; USE_BRACKEN_VAGINAL="0"; USE_BRACKEN_NONVAGINAL="0"; VALENCIA_FORCE_BRACKEN="0"
    log_warn "Bracken not found. Bracken will be skipped; VALENCIA can fallback to kreport."
    return 0
  fi
  [[ -n "${KRAKEN2_DB}" && "${KRAKEN2_DB}" != "null" ]] || {
    BRACKEN_AVAILABLE="0"; USE_BRACKEN_VAGINAL="0"; USE_BRACKEN_NONVAGINAL="0"; VALENCIA_FORCE_BRACKEN="0"
    log_warn "KRAKEN2_DB not set; bracken disabled."
    return 0
  }
  # Check vaginal kmer_distrib (skip "auto" — resolved later by auto_select_bracken_readlen)
  if [[ "${BRACKEN_READLEN_VAGINAL}" != "auto" && -n "${BRACKEN_READLEN_VAGINAL}" ]]; then
    local kmer_vag="${KRAKEN2_DB}/database${BRACKEN_READLEN_VAGINAL}mers.kmer_distrib"
    if [[ ! -s "${kmer_vag}" ]]; then
      USE_BRACKEN_VAGINAL="0"; VALENCIA_FORCE_BRACKEN="0"
      log_warn "Bracken kmer_distrib missing for vaginal readlen=${BRACKEN_READLEN_VAGINAL}: ${kmer_vag}"
    fi
  fi
  # Check nonvaginal kmer_distrib independently
  if [[ "${BRACKEN_READLEN_NONVAGINAL}" != "auto" && -n "${BRACKEN_READLEN_NONVAGINAL}" ]]; then
    local kmer_nv="${KRAKEN2_DB}/database${BRACKEN_READLEN_NONVAGINAL}mers.kmer_distrib"
    if [[ ! -s "${kmer_nv}" ]]; then
      USE_BRACKEN_NONVAGINAL="0"
      log_warn "Bracken kmer_distrib missing for nonvaginal readlen=${BRACKEN_READLEN_NONVAGINAL}: ${kmer_nv}"
    fi
  fi
  BRACKEN_AVAILABLE="1"
}

############################################
##     BARCODE SITE MAPPING (vaginal etc) ##
############################################
# Read sample_type from config (like sr_meta does)
# This allows FASTQ_SINGLE mode to set sample type directly without a sample sheet
SAMPLE_TYPE_RAW="$(jq_first "${CONFIG_PATH}" '.input.sample_type' '.specimen' '.sample_type' '.inputs.sample_type' '.run.sample_type' || true)"
SAMPLE_TYPE_NORM="$(printf "%s" "${SAMPLE_TYPE_RAW:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
[[ -n "${SAMPLE_TYPE_NORM}" ]] || SAMPLE_TYPE_NORM="unknown"

# Associative array: barcode -> site (e.g. "barcode01" -> "vaginal")
declare -A SITE_BY_BARCODE
# Associative array: barcode -> friendly name (e.g. "barcode01" -> "Sample_A")
declare -A NAME_BY_BARCODE

# Load barcode-to-site mapping from sample sheet (TSV with columns: barcode, site)
# If sample sheet not provided or doesn't exist, all barcodes default to "unknown"
# EXCEPT: If input.sample_type is set in config, use that for FASTQ_SINGLE mode
load_barcode_site_map() {
  local sheet="${1:-}"
  SITE_BY_BARCODE=()
  NAME_BY_BARCODE=()

  # If no sample sheet provided but sample_type is set globally, will fall back to SAMPLE_TYPE_NORM
  # This allows --sample-type vaginal to apply to all barcodes without a sample sheet
  if [[ -z "${sheet}" || "${sheet}" == "null" ]]; then
    if [[ -n "${SAMPLE_TYPE_NORM}" && "${SAMPLE_TYPE_NORM}" != "unknown" ]]; then
      log_info "No sample sheet provided; using global sample_type='${SAMPLE_TYPE_RAW}' for all barcodes."
    else
      log_info "No sample sheet provided; all barcodes treated as unknown site."
    fi
    return 0
  fi

  if [[ ! -f "${sheet}" ]]; then
    log_warn "Sample sheet not found: ${sheet}; all barcodes treated as unknown site."
    return 0
  fi

  log_info "Loading barcode site map from: ${sheet}"
  local line_num=0
  while IFS=$'\t' read -r barcode site rest; do
    ((line_num++)) || true
    # Skip header or empty lines
    [[ -z "${barcode}" || "${barcode}" == "barcode" ]] && continue
    # Normalize barcode name (lowercase)
    barcode="$(echo "${barcode}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    site="$(echo "${site}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    SITE_BY_BARCODE["${barcode}"]="${site}"
  done < "${sheet}"

  log_info "Loaded site mapping for ${#SITE_BY_BARCODE[@]} barcodes"
}

# Check if a barcode should be treated as a vaginal sample
# Returns 0 (true) if vaginal, 1 (false) otherwise
# Falls back to global SAMPLE_TYPE_NORM if barcode not in mapping
is_vaginal_barcode() {
  local barcode="${1:-}"
  local site="${SITE_BY_BARCODE[${barcode}]:-${SAMPLE_TYPE_NORM:-unknown}}"
  [[ "${site}" == "vaginal" || "${site}" == "vag" || "${site}" == "v" ]]
}

# Get site name for a barcode (returns global SAMPLE_TYPE_NORM or "unknown" if not mapped)
get_site_for_barcode() {
  local barcode="${1:-}"
  echo "${SITE_BY_BARCODE[${barcode}]:-${SAMPLE_TYPE_NORM:-unknown}}"
}

# Get friendly name for a barcode (returns barcode ID if no name mapped)
get_name_for_barcode() {
  local barcode="${1:-}"
  # If NAME_BY_BARCODE has an entry, use it; otherwise return the barcode itself
  if [[ -n "${NAME_BY_BARCODE[${barcode}]:-}" ]]; then
    echo "${NAME_BY_BARCODE[${barcode}]}"
  else
    echo "${barcode}"
  fi
}

convert_fast5_to_pod5() {
  [[ -n "${STAGED_FAST5_DIR}" ]] || die "No staged FAST5 dir found"
  check_cmd "${POD5_BIN}"
  local outpod5="${POD5_STAGE_DIR}/${RUN_NAME}.pod5"

  if [[ -s "${outpod5}" ]]; then
    log_info "Resume: POD5 exists, skipping: ${outpod5}"
    echo "${outpod5}"
    return 0
  fi

  "${POD5_BIN}" convert fast5 "${STAGED_FAST5_DIR}" -o "${outpod5}"
  echo "${outpod5}"
}

dorado_basecall_to_bam() {
  check_cmd "${DORADO_BIN}"
  [[ -n "${DORADO_MODEL}" && "${DORADO_MODEL}" != "null" ]] || die "Missing dorado model: set tools.dorado.model"
  local pod5_path="$1"
  local outbam="${BAM_STAGE_DIR}/${RUN_NAME}.bam"

  if [[ -s "${outbam}" ]]; then
    log_info "Resume: BAM exists, skipping basecalling: ${outbam}"
    echo "${outbam}"
    return 0
  fi

  # Download Dorado model if not already present
  # Models are stored in ~/.cache/dorado/models or /dorado_models
  local model_dir="${DORADO_MODEL_DIR:-/dorado_models}"
  mkdir -p "${model_dir}"

  # Check if model needs to be downloaded (Dorado will download automatically if needed,
  # but we log it explicitly for visibility)
  log_info "Using Dorado model: ${DORADO_MODEL}"
  log_info "Downloading model if not cached (this may take a while on first run)..."

  # Use dorado download to ensure model is available (output to stderr)
  "${DORADO_BIN}" download --model "${DORADO_MODEL}" --directory "${model_dir}" 2>&1 | head -20 >&2 || {
    log_warn "Model download step completed (may have already been cached)"
  }

  # Run basecaller with explicit model path if downloaded to custom location
  local model_path="${model_dir}/${DORADO_MODEL}"
  if [[ -d "${model_path}" ]]; then
    log_info "Using downloaded model at: ${model_path}"
    "${DORADO_BIN}" basecaller --device cpu "${model_path}" "${pod5_path}" > "${outbam}"
  else
    # Fall back to model name (Dorado will use default cache)
    "${DORADO_BIN}" basecaller --device cpu "${DORADO_MODEL}" "${pod5_path}" > "${outbam}"
  fi
  echo "${outbam}"
}

dorado_demux_to_per_barcode_bam() {
  check_cmd "${DORADO_BIN}"
  local inbam="$1"
  local outdir="${DEMUX_DIR}/${RUN_NAME}"
  make_dir "${outdir}"

  if [[ -z "${BARCODE_KIT:-}" || "${BARCODE_KIT}" == "null" ]]; then
    local single_name="${SINGLE_SAMPLE_NAME:-${RUN_NAME_BASE}}"
    log_warn "barcode_kit empty; treating as single sample '${single_name}'"
    cp "${inbam}" "${outdir}/${single_name}.bam"
    echo "${outdir}"
    return 0
  fi

  local demux_log="${outdir}/dorado_demux.log"
  "${DORADO_BIN}" demux --kit-name "${BARCODE_KIT}" --output-dir "${outdir}" "${inbam}" > "${demux_log}" 2>&1 || die "Dorado demux failed. See: ${demux_log}"

  shopt -s nullglob
  local demux_bams=( "${outdir}"/*.bam "${outdir}"/*/*.bam )
  [[ ${#demux_bams[@]} -gt 0 ]] || die "Dorado demux produced no BAMs. See: ${demux_log}"

  echo "${outdir}"
}

dorado_trim_bam_to_fastq_per_barcode() {
  check_cmd "${DORADO_BIN}"
  check_cmd "${SAMTOOLS_BIN}"

  local demux_dir="$1"
  make_dir "${TRIM_DIR}"
  make_dir "${RAW_READS_DIR}/${RUN_NAME}"

  shopt -s nullglob
  local any=0
  for bbam in "${demux_dir}"/*.bam "${demux_dir}"/*/*.bam; do
    [[ -e "${bbam}" ]] || continue
    any=1

    local barcode
    barcode="$(basename "${bbam}" .bam)"

    local trimmed_bam="${TRIM_DIR}/${RUN_NAME}_${barcode}_trimmed.bam"
    # Note: dorado trim auto-detects adapters/primers. Custom primers can be provided via --primer-sequences.
    local cmd=( "${DORADO_BIN}" trim "${bbam}" )
    if [[ -n "${SEQUENCING_KIT:-}" && "${SEQUENCING_KIT}" != "null" ]]; then
      cmd+=( --sequencing-kit "${SEQUENCING_KIT}" )
    fi
    if [[ -n "${PRIMER_FASTA:-}" && "${PRIMER_FASTA}" != "null" && -s "${PRIMER_FASTA}" ]]; then
      cmd+=( --primer-sequences "${PRIMER_FASTA}" )
    fi

    "${cmd[@]}" > "${trimmed_bam}"

    local fqdir="${RAW_READS_DIR}/${RUN_NAME}/${barcode}"
    make_dir "${fqdir}"
    local fq="${fqdir}/${barcode}.fastq"
    "${SAMTOOLS_BIN}" bam2fq "${trimmed_bam}" > "${fq}"
  done

  [[ "${any}" -eq 1 ]] || die "No demux BAMs found under ${demux_dir}"
  echo "${RAW_READS_DIR}/${RUN_NAME}"
}

############################################
##   FASTQC + MULTIQC (RAW FASTQ INPUT)   ##
############################################

qc_raw_per_barcode_fastq() {
  check_cmd "${FASTQC_BIN}"
  check_cmd "${MULTIQC_BIN}"
  make_dir "${RAW_FASTQC_DIR}"
  make_dir "${RAW_MULTIQC_DIR}"

  shopt -s nullglob
  local files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz )
  [[ ${#files[@]} -gt 0 ]] || die "No per-barcode FASTQ files found under ${PER_BARCODE_FASTQ_ROOT}"

  for fq in "${files[@]}"; do
    log "FastQC on ${fq}"
    "${FASTQC_BIN}" -t "${THREADS}" -o "${RAW_FASTQC_DIR}" "${fq}"
  done

  "${MULTIQC_BIN}" "${RAW_FASTQC_DIR}" -o "${RAW_MULTIQC_DIR}"
}

############################################
##   Q-FILTER (NanoFilt, MEAN Q >= X)     ##
############################################

qfilter_mean_q_per_barcode() {
  [[ "${QFILTER_ENABLED}" == "1" ]] || { log_warn "Skipping Q-filter (qfilter.enabled=0)"; return 0; }

  # Check if NanoFilt is available - skip gracefully if not
  if ! command -v "${NANOFILT_BIN}" >/dev/null 2>&1; then
    log_warn "Skipping Q-filter (NanoFilt not found at ${NANOFILT_BIN} - set tools.nanofilt_bin or install NanoFilt)"
    return 0
  fi

  local out_root="${QFILTER_DIR}/${RUN_NAME_BASE}"
  make_dir "${out_root}"

  shopt -s nullglob
  local files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz )
  [[ ${#files[@]} -gt 0 ]] || die "No per-barcode FASTQ found under ${PER_BARCODE_FASTQ_ROOT}"

  for fq in "${files[@]}"; do
    local barcode
    barcode="$(basename "$(dirname "${fq}")")"

    make_dir "${out_root}/${barcode}"
    local out_fq="${out_root}/${barcode}/${barcode}.q${QFILTER_MIN_Q}.fastq.gz"

    log "Q-filter: ${fq} -> ${out_fq}"
    if [[ "${fq}" == *.gz ]]; then
      gzip -cd "${fq}" | "${NANOFILT_BIN}" -q "${QFILTER_MIN_Q}" | gzip -c > "${out_fq}"
    else
      "${NANOFILT_BIN}" -q "${QFILTER_MIN_Q}" < "${fq}" | gzip -c > "${out_fq}"
    fi
  done

  PER_BARCODE_FASTQ_ROOT="${out_root}"
}

############################################
##    HUMAN READ REMOVAL (minimap2 ONT)   ##
############################################

human_depletion_per_barcode() {
  check_cmd "${MINIMAP2_BIN}"
  check_cmd "${SAMTOOLS_BIN}"

  local idx=""

  # Prefer pre-built .mmi index (saves memory vs building on-the-fly)
  if [[ -n "${GRCH38_MMI}" && "${GRCH38_MMI}" != "null" && -s "${GRCH38_MMI}" ]]; then
    idx="${GRCH38_MMI}"
    log_info "Using pre-built minimap2 index: ${idx}"
  elif [[ -n "${GRCH38_FA}" && "${GRCH38_FA}" != "null" ]]; then
    require_file "${GRCH38_FA}"
    idx="${INDEX_DIR}/GRCh38.mmi"
    if [[ ! -s "${idx}" ]]; then
      log_info "Building minimap2 index from FASTA (this uses significant memory)..."
      "${MINIMAP2_BIN}" -d "${idx}" "${GRCH38_FA}"
    fi
  else
    log_warn "No human reference configured (set tools.minimap2.human_mmi or tools.minimap2.human_fa) - skipping host depletion"
    NONHUMAN_RUN_DIR="${PER_BARCODE_FASTQ_ROOT}"
    return 0
  fi

  shopt -s nullglob
  local files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz )
  [[ ${#files[@]} -gt 0 ]] || die "No FASTQ files found in ${PER_BARCODE_FASTQ_ROOT} for human depletion"

  for fq in "${files[@]}"; do
    local barcode
    barcode="$(basename "$(dirname "${fq}")")"

    make_dir "${ALN_DIR}/${RUN_NAME_BASE}/${barcode}"
    make_dir "${NONHUMAN_DIR}/${RUN_NAME_BASE}/${barcode}"

    local bam="${ALN_DIR}/${RUN_NAME_BASE}/${barcode}/${barcode}.sorted.bam"
    local unmapped="${NONHUMAN_DIR}/${RUN_NAME_BASE}/${barcode}/unmapped.bam"
    local nonhuman_name="${NONHUMAN_DIR}/${RUN_NAME_BASE}/${barcode}/nonhuman.name.bam"
    local nonhuman_fq="${NONHUMAN_DIR}/${RUN_NAME_BASE}/${barcode}/nonhuman.fastq.gz"

    # Use --split-prefix for multi-part/split indices (low-RAM mode)
    # This is required when the .mmi index was built with -I (split) or when using lowmem indices
    if [[ "${MINIMAP2_SPLIT_PREFIX}" == "1" ]]; then
      local split_tmp="${ALN_DIR}/${RUN_NAME_BASE}/${barcode}/mm2_split"
      log_info "Using minimap2 split-prefix mode for low-RAM alignment"
      "${MINIMAP2_BIN}" -t "${THREADS}" -ax map-ont --secondary=no --split-prefix "${split_tmp}" "${idx}" "${fq}" \
        | "${SAMTOOLS_BIN}" sort -@ "${SAMTOOLS_THREADS}" -o "${bam}"
      # Clean up split temp files if any remain
      rm -f "${split_tmp}".*.sam 2>/dev/null || true
    else
      "${MINIMAP2_BIN}" -t "${THREADS}" -ax map-ont --secondary=no "${idx}" "${fq}" \
        | "${SAMTOOLS_BIN}" sort -@ "${SAMTOOLS_THREADS}" -o "${bam}"
    fi
    "${SAMTOOLS_BIN}" index "${bam}"

    "${SAMTOOLS_BIN}" view -@ "${SAMTOOLS_THREADS}" -b -f 4 "${bam}" > "${unmapped}"
    "${SAMTOOLS_BIN}" sort -n -@ "${SAMTOOLS_THREADS}" -o "${nonhuman_name}" "${unmapped}"
    "${SAMTOOLS_BIN}" fastq -@ "${SAMTOOLS_THREADS}" "${nonhuman_name}" | gzip -c > "${nonhuman_fq}"

    "${SAMTOOLS_BIN}" flagstat "${bam}" > "${ALN_DIR}/${RUN_NAME_BASE}/${barcode}/${barcode}.flagstat.txt"
  done

  NONHUMAN_RUN_DIR="${NONHUMAN_DIR}/${RUN_NAME_BASE}"
  log_info "Non-human FASTQs prepared at: ${NONHUMAN_RUN_DIR}"
}

############################################
##  KRAKEN2 + KRONA (+ BRACKEN optional)  ##
############################################

taxonomy_per_barcode_fixed_params() {
  # Check if kraken2 db is configured - skip taxonomy if not
  if [[ -z "${KRAKEN2_DB}" || "${KRAKEN2_DB}" == "null" ]]; then
    log_warn "KRAKEN2_DB not set - skipping taxonomy step. Set tools.kraken2.db to enable."
    return 0
  fi

  if [[ ! -d "${KRAKEN2_DB}" ]]; then
    log_warn "KRAKEN2_DB directory not found: ${KRAKEN2_DB} - skipping taxonomy step."
    return 0
  fi

  # Check if kraken2 command is available
  if ! command -v "${KRAKEN2_BIN}" >/dev/null 2>&1; then
    log_warn "Kraken2 not found - skipping taxonomy step."
    return 0
  fi

  check_bracken_available
  [[ -n "${NONHUMAN_RUN_DIR}" ]] || die "nonhuman_run_dir is not set (human depletion must run first)"

  make_dir "${TAXO_ROOT}/${RUN_NAME}"

  shopt -s nullglob
  local nfqs=( "${NONHUMAN_RUN_DIR}"/*/nonhuman.fastq.gz )
  [[ ${#nfqs[@]} -gt 0 ]] || die "No nonhuman.fastq.gz found under ${NONHUMAN_RUN_DIR}"

  for nfq in "${nfqs[@]}"; do
    local sample_id
    sample_id="$(basename "$(dirname "${nfq}")")"
    local friendly
    friendly="$(get_name_for_barcode "${sample_id}")"

    make_dir "${TAXO_ROOT}/${RUN_NAME}/${sample_id}"
    local bout="${TAXO_ROOT}/${RUN_NAME}/${sample_id}"

    local conf mhg do_bracken br_readlen
    do_bracken=0
    br_readlen=""

    if is_vaginal_barcode "${sample_id}"; then
      conf="${KRAKEN_CONF_VAGINAL}"
      mhg="${KRAKEN_MHG_VAGINAL}"
      br_readlen="${BRACKEN_READLEN_VAGINAL}"
      log_info "Sample ${sample_id} (${friendly}) flagged as vaginal."
      if [[ "${BRACKEN_AVAILABLE}" -eq 1 && "${USE_BRACKEN_VAGINAL}" -eq 1 ]]; then
        do_bracken=1
      fi
    else
      conf="${KRAKEN_CONF_NONVAGINAL}"
      mhg="${KRAKEN_MHG_NONVAGINAL}"
      log_info "Sample ${sample_id} (${friendly}) treated as non-vaginal ($(get_site_for_barcode "${sample_id}")${SITE_BY_BARCODE[${sample_id}]:+})."
      if [[ "${BRACKEN_AVAILABLE}" -eq 1 && "${USE_BRACKEN_NONVAGINAL}" -eq 1 ]]; then
        do_bracken=1
        br_readlen="${BRACKEN_READLEN_NONVAGINAL}"
      fi
    fi

    log "Kraken2 (${sample_id}) --confidence ${conf}, --minimum-hit-groups ${mhg}"
    "${KRAKEN2_BIN}" \
      --db "${KRAKEN2_DB}" \
      --threads "${THREADS}" \
      --memory-mapping \
      --use-names \
      --confidence "${conf}" \
      --minimum-hit-groups "${mhg}" \
      --report "${bout}/${sample_id}.kreport" \
      --output "${bout}/${sample_id}.kraken2" \
      "${nfq}"

    if is_vaginal_barcode "${sample_id}"; then
      log "Skipping Krona for vaginal sample ${sample_id} (${friendly})."
    elif [[ -z "${KREPORT2KRONA_BIN}" || ! -x "${KREPORT2KRONA_BIN}" ]] && ! command -v "${KREPORT2KRONA_BIN:-kreport2krona.py}" &>/dev/null; then
      log_warn "Krona tools not available - skipping Krona for ${sample_id}"
    elif [[ -z "${KTIMPORT_BIN}" || ! -x "${KTIMPORT_BIN}" ]] && ! command -v "${KTIMPORT_BIN:-ktImportText}" &>/dev/null; then
      log_warn "Krona tools not available - skipping Krona for ${sample_id}"
    else
      log "Krona (${sample_id})"
      "${KREPORT2KRONA_BIN}" -r "${bout}/${sample_id}.kreport" -o "${bout}/${sample_id}.krona.txt" || log_warn "kreport2krona failed for ${sample_id}"
      if [[ -s "${bout}/${sample_id}.krona.txt" ]]; then
        "${KTIMPORT_BIN}" "${bout}/${sample_id}.krona.txt" -o "${bout}/${sample_id}.krona.html" || log_warn "ktImportText failed for ${sample_id}"
      fi
    fi

    if [[ "${do_bracken}" -eq 1 ]]; then
      log "Bracken (${sample_id}), readlen=${br_readlen}"
      "${BRACKEN_BIN}" \
        -d "${KRAKEN2_DB}" \
        -i "${bout}/${sample_id}.kreport" \
        -o "${bout}/${sample_id}.bracken" \
        -w "${bout}/${sample_id}.breport" \
        -r "${br_readlen}" \
        -l S || log_warn "Bracken failed for ${sample_id} — continuing (VALENCIA can fallback)."
    else
      log "Skipping Bracken for ${sample_id} (${friendly})."
    fi
  done
}

############################################
##       VALENCIA (mirroring sr_amp)      ##
############################################

# VALENCIA runs inline Python (no external Valencia.py dependency)
# This mirrors the sr_amp approach for consistency across all pipelines

run_valencia() {
  local taxo_run_dir="${TAXO_ROOT}/${RUN_NAME}"

  # Determine if VALENCIA should run
  VALENCIA_SHOULD_RUN="no"
  if [[ "${VALENCIA_ENABLED}" == "true" ]]; then
    VALENCIA_SHOULD_RUN="yes"
  elif [[ "${VALENCIA_ENABLED}" == "auto" ]]; then
    if [[ "${SAMPLE_TYPE_NORM}" == "vaginal" ]]; then
      VALENCIA_SHOULD_RUN="yes"
    fi
  fi

  if [[ "${VALENCIA_SHOULD_RUN}" != "yes" ]]; then
    local started ended
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "valencia" "skipped" "VALENCIA skipped (enabled=${VALENCIA_ENABLED}, sample_type=${SAMPLE_TYPE_RAW:-})" "" "" "0" "${started}" "${ended}"
    return 0
  fi

  # Check for kreport files
  if [[ ! -d "${taxo_run_dir}" ]]; then
    local started ended
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "valencia" "skipped" "VALENCIA skipped - no taxonomy results at ${taxo_run_dir}" "" "" "0" "${started}" "${ended}"
    return 0
  fi

  # Check centroids CSV
  if [[ -z "${VALENCIA_CENTROIDS_CSV}" || "${VALENCIA_CENTROIDS_CSV}" == "null" || ! -s "${VALENCIA_CENTROIDS_CSV}" ]]; then
    local started ended
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "valencia" "failed" "VALENCIA enabled but centroids_csv missing. Set --valencia-centroids PATH" "" "" "2" "${started}" "${ended}"
    log_warn "VALENCIA enabled but centroids CSV missing. Use --valencia-centroids to specify path."
    return 0
  fi

  # Setup output directories
  VALENCIA_DIR="${RESULTS_DIR}/valencia"
  VALENCIA_LOG="${LOGS_DIR}/valencia.log"
  VALENCIA_PLOTS_DIR="${VALENCIA_DIR}/plots"
  mkdir -p "${VALENCIA_DIR}" "${VALENCIA_PLOTS_DIR}"

  VALENCIA_INPUT_CSV="${VALENCIA_DIR}/taxon_table_kreport.csv"
  VALENCIA_OUTPUT_CSV="${VALENCIA_DIR}/output.csv"
  VALENCIA_ASSIGNMENTS_CSV="${VALENCIA_DIR}/valencia_assignments.csv"

  log_info "Running VALENCIA classification..."
  log_info "  Centroids: ${VALENCIA_CENTROIDS_CSV}"
  log_info "  Taxonomy dir: ${taxo_run_dir}"

  local started ended ec
  started="$(iso_now)"
  set +e
  python3 - "${VALENCIA_CENTROIDS_CSV}" "${taxo_run_dir}" "${VALENCIA_DIR}" "${VALENCIA_PLOTS_DIR}" >>"${VALENCIA_LOG}" 2>&1 <<'VALENCIA_PY'
import sys, os, re, csv, math
from pathlib import Path

centroids_csv, taxo_run_dir, out_dir, plots_dir = sys.argv[1:]
os.makedirs(out_dir, exist_ok=True)
os.makedirs(plots_dir, exist_ok=True)

# -----------------------------
# Helpers: taxa name normalization (match VALENCIA centroids format)
# -----------------------------
bc_focal = {'Lactobacillus','Prevotella','Gardnerella','Atopobium','Sneathia'}

def norm_taxa_name(name: str) -> str:
    """Normalize taxa name to match VALENCIA centroids format."""
    name = (name or "").strip()
    # Remove leading spaces/indentation from kreport
    name = name.lstrip()
    # Replace spaces with underscores
    name = name.replace(" ", "_")
    return name

def kreport_to_valencia_taxa(genus: str, species: str) -> str:
    """Convert Kraken2 genus/species to VALENCIA taxa format."""
    genus = (genus or "").strip()
    species = (species or "").strip()

    if genus in bc_focal and species:
        # For focal genera, use Genus_species format
        return f"{genus}_{species}"
    elif genus:
        # For other genera, use g_Genus format
        return f"g_{genus}"
    elif species:
        return f"s_{species}"
    return "None"

# Manual corrections from VALENCIA's convert_qiime.py
taxa_fixes = {
    'g_Gardnerella': 'Gardnerella_vaginalis',
    'Lactobacillus_acidophilus/casei/crispatus/gallinarum': 'Lactobacillus_crispatus',
    'Lactobacillus_fornicalis/jensenii': 'Lactobacillus_jensenii',
    'g_Escherichia/Shigella': 'g_Escherichia.Shigella',
    'Lactobacillus_gasseri/johnsonii': 'Lactobacillus_gasseri'
}

def apply_taxa_fixes(name: str) -> str:
    return taxa_fixes.get(name, name)

# -----------------------------
# Parse kreport files
# -----------------------------
def parse_kreport(path: str):
    """Parse Kraken2 report file, return dict of taxa -> read counts at species level."""
    taxa_counts = {}
    total_reads = 0

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 6:
                continue

            try:
                pct = float(parts[0].strip())
                clade_reads = int(parts[1].strip())
                taxon_reads = int(parts[2].strip())
            except (ValueError, IndexError):
                continue

            rank = (parts[3] or "").strip()
            name = (parts[5] or "").strip().lstrip()

            # Count total reads from root
            if rank == "R" or (rank == "U" and "unclassified" in name.lower()):
                total_reads = clade_reads

            # Only use species-level classifications for VALENCIA
            if rank != "S":
                continue

            if not name or clade_reads <= 0:
                continue

            # Normalize the taxa name
            taxa_name = norm_taxa_name(name)
            taxa_counts[taxa_name] = taxa_counts.get(taxa_name, 0) + clade_reads

    return taxa_counts, total_reads

# Find all kreport files
taxo_path = Path(taxo_run_dir)
kreport_files = list(taxo_path.glob("*/*.kreport"))

if not kreport_files:
    print(f"WARNING: No kreport files found in {taxo_run_dir}")
    sys.exit(0)

print(f"Found {len(kreport_files)} kreport file(s)")

# Build sample data from kreports (prefer Bracken-corrected .breport when present)
samples_data = []
all_taxa = set()

for kreport_path in kreport_files:
    sample_id = kreport_path.parent.name
    source_path = kreport_path
    breport_candidate = kreport_path.parent / f"{sample_id}.breport"
    if breport_candidate.exists() and breport_candidate.stat().st_size > 0:
        source_path = breport_candidate
        print(f"  Using Bracken-corrected report for {sample_id}: {breport_candidate.name}")
    taxa_counts, total_reads = parse_kreport(source_path)

    if not taxa_counts:
        print(f"  Skipping {sample_id}: no species-level taxa found")
        continue

    # Use clade reads sum if total_reads not found
    if total_reads == 0:
        total_reads = sum(taxa_counts.values())

    samples_data.append({
        "sample_id": sample_id,
        "taxa_counts": taxa_counts,
        "total_reads": total_reads
    })
    all_taxa.update(taxa_counts.keys())
    print(f"  Parsed {sample_id}: {len(taxa_counts)} taxa, {total_reads} total reads")

if not samples_data:
    print("WARNING: No valid samples found for VALENCIA")
    sys.exit(0)

# -----------------------------
# Load centroids CSV
# -----------------------------
centroid_rows = []
with open(centroids_csv, "r", encoding="utf-8", errors="replace", newline="") as f:
    reader = csv.DictReader(f)
    if not reader.fieldnames:
        raise SystemExit("ERROR: centroids CSV appears empty")
    fields = list(reader.fieldnames)

    # Tolerate subCST naming variant
    if "sub_CST" not in fields and "subCST" in fields:
        fields = ["sub_CST" if x == "subCST" else x for x in fields]

    if "sub_CST" not in fields:
        raise SystemExit("ERROR: centroids CSV missing 'sub_CST' column")

    for row in reader:
        centroid_rows.append(row)

if not centroid_rows:
    raise SystemExit("ERROR: centroids CSV has no rows")

# Determine centroid taxa columns
ignore_cols = {"sampleID", "read_count", "sub_CST", "subCST"}
centroid_taxa_cols = [c for c in centroid_rows[0].keys() if c not in ignore_cols]

print(f"Loaded {len(centroid_rows)} centroids with {len(centroid_taxa_cols)} taxa columns")

# Build centroid vectors
centroids = {}
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

# CST ordering
CSTs = ['I-A','I-B','II','III-A','III-B','IV-A','IV-B','IV-C0','IV-C1','IV-C2','IV-C3','IV-C4','V']

# -----------------------------
# Build taxa mapping from kreport names to centroid names
# -----------------------------
def normalize_for_matching(s: str) -> str:
    """Normalize taxa name for fuzzy matching."""
    s = (s or "").strip().lower()
    s = s.replace(" ", "_").replace("-", "_").replace(".", "_")
    s = re.sub(r"[^a-z0-9_]", "", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s

centroid_taxa_norm = {normalize_for_matching(t): t for t in centroid_taxa_cols}

# -----------------------------
# Write input CSV (sample x taxa counts)
# -----------------------------
taxon_table_csv = os.path.join(out_dir, "taxon_table_kreport.csv")

# Use centroid taxa columns for consistency
with open(taxon_table_csv, "w", encoding="utf-8", newline="") as out:
    w = csv.writer(out)
    w.writerow(["sampleID", "read_count", *centroid_taxa_cols])

    for sample in samples_data:
        sid = sample["sample_id"]
        total = sample["total_reads"]
        taxa_counts = sample["taxa_counts"]

        # Map kreport taxa to centroid taxa
        row_counts = {t: 0 for t in centroid_taxa_cols}
        for kreport_taxa, count in taxa_counts.items():
            kreport_norm = normalize_for_matching(kreport_taxa)
            if kreport_norm in centroid_taxa_norm:
                canonical = centroid_taxa_norm[kreport_norm]
                row_counts[canonical] += count

        row = [sid, total]
        row.extend([row_counts.get(t, 0) for t in centroid_taxa_cols])
        w.writerow(row)

print(f"OK: VALENCIA input -> {taxon_table_csv}")

# -----------------------------
# Yue-Clayton similarity function
# -----------------------------
def yue_similarity(obs_vec, med_vec):
    product = 0.0
    diff_sq = 0.0
    for o, m in zip(obs_vec, med_vec):
        product += (m * o)
        d = (m - o)
        diff_sq += (d * d)
    denom = diff_sq + product
    return (product / denom) if denom != 0 else 0.0

# -----------------------------
# Run VALENCIA classification
# -----------------------------
out_rows = []

for sample in samples_data:
    sid = sample["sample_id"]
    total = sample["total_reads"]
    taxa_counts = sample["taxa_counts"]

    # Build relative abundance vector aligned to centroid taxa
    row_counts = {t: 0 for t in centroid_taxa_cols}
    for kreport_taxa, count in taxa_counts.items():
        kreport_norm = normalize_for_matching(kreport_taxa)
        if kreport_norm in centroid_taxa_norm:
            canonical = centroid_taxa_norm[kreport_norm]
            row_counts[canonical] += count

    obs_vec = []
    total_matched = sum(row_counts.values())
    if total_matched > 0:
        for t in centroid_taxa_cols:
            obs_vec.append(float(row_counts.get(t, 0)) / float(total_matched))
    else:
        obs_vec = [0.0 for _ in centroid_taxa_cols]

    # Compute similarity to each CST centroid
    sims = {}
    for cst in CSTs:
        if cst in centroids:
            sims[cst] = yue_similarity(obs_vec, centroids[cst])
        else:
            sims[cst] = float("nan")

    # Pick best match
    best_cst = None
    best_score = -1.0
    for cst in CSTs:
        v = sims.get(cst)
        if v is None or (isinstance(v, float) and math.isnan(v)):
            continue
        if v > best_score:
            best_score = v
            best_cst = cst

    subcst = best_cst or ""
    score = best_score if best_cst else float("nan")

    # Collapse CST groups
    cst_group = subcst
    if subcst in ("I-A", "I-B"):
        cst_group = "I"
    elif subcst in ("III-A", "III-B"):
        cst_group = "III"
    elif subcst in ("IV-C0", "IV-C1", "IV-C2", "IV-C3", "IV-C4"):
        cst_group = "IV-C"

    out_row = {"sampleID": sid, "read_count": total}
    # Include taxa counts
    for t in centroid_taxa_cols:
        out_row[t] = row_counts.get(t, 0)
    # Similarity columns
    for cst in CSTs:
        out_row[f"{cst}_sim"] = sims.get(cst)
    out_row["subCST"] = subcst
    out_row["score"] = score
    out_row["CST"] = cst_group
    out_rows.append(out_row)

# -----------------------------
# Write output CSVs
# -----------------------------
def write_output_csv(path):
    if not out_rows:
        raise SystemExit("ERROR: No VALENCIA output rows to write")
    sim_cols = [f"{c}_sim" for c in CSTs]
    fieldnames = ["sampleID", "read_count", *centroid_taxa_cols, *sim_cols, "subCST", "score", "CST"]
    with open(path, "w", encoding="utf-8", newline="") as out:
        w = csv.DictWriter(out, fieldnames=fieldnames)
        w.writeheader()
        for r in out_rows:
            w.writerow(r)

out_csv = os.path.join(out_dir, "output.csv")
compat_csv = os.path.join(out_dir, "valencia_assignments.csv")
write_output_csv(out_csv)
write_output_csv(compat_csv)

print(f"OK: VALENCIA output -> {out_csv}")

# -----------------------------
# Generate SVG similarity plots
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

    vals = []
    for v in values:
        if v is None or (isinstance(v, float) and math.isnan(v)):
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

    esc = lambda s: (s or "").replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")
    parts = []
    parts.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">')
    parts.append(f'<rect x="0" y="0" width="{w}" height="{h}" fill="white"/>')
    parts.append(f'<text x="{pad_l}" y="24" font-family="Arial" font-size="16" fill="black">{esc(title)}</text>')
    parts.append(f'<line x1="{pad_l}" y1="{pad_t+inner_h}" x2="{pad_l+inner_w}" y2="{pad_t+inner_h}" stroke="black" stroke-width="1"/>')

    x = pad_l
    for i, (lab, v) in enumerate(zip(labels, vals)):
        bh = int((v / max_v) * inner_h)
        y = pad_t + inner_h - bh
        parts.append(f'<rect x="{x}" y="{y}" width="{bar_w}" height="{bh}" fill="#444"/>')
        lx = x + bar_w/2
        parts.append(f'<text x="{lx}" y="{pad_t+inner_h+14}" font-family="Arial" font-size="10" fill="black" text-anchor="middle">{esc(lab)}</text>')
        x += bar_w + bar_gap

    parts.append(f'<text x="{pad_l}" y="{pad_t+inner_h+28}" font-family="Arial" font-size="10" fill="black">0</text>')
    parts.append(f'<text x="{pad_l}" y="{pad_t+10}" font-family="Arial" font-size="10" fill="black">{max_v:.3f}</text>')
    parts.append('</svg>')

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))

for r in out_rows:
    sid = r.get("sampleID", "")
    sims = [r.get(f"{cst}_sim") for cst in CSTs]
    title = f"VALENCIA similarities for {sid} (subCST={r.get('subCST','')}, CST={r.get('CST','')})"
    out_path = os.path.join(plots_dir, f"{sid}_valencia_similarity.svg")
    svg_barplot(sid, title, sims, CSTs, out_path)

print(f"OK: VALENCIA plots -> {plots_dir}")
print("VALENCIA classification complete")
VALENCIA_PY
  ec=$?
  set -e
  ended="$(iso_now)"

  if [[ $ec -ne 0 ]]; then
    steps_append "${STEPS_JSON}" "valencia" "failed" "VALENCIA classification failed (see logs/valencia.log)" "python3" "VALENCIA inline" "${ec}" "${started}" "${ended}"
    log_warn "VALENCIA failed. See: ${VALENCIA_LOG}"
  else
    steps_append "${STEPS_JSON}" "valencia" "succeeded" "VALENCIA produced output.csv and plots" "python3" "VALENCIA inline" "0" "${started}" "${ended}"
    log_info "VALENCIA completed successfully"

    # Update outputs.json with valencia paths
    local tmp="${OUTPUTS_JSON}.tmp"
    jq --arg valencia_dir "${VALENCIA_DIR}" \
       --arg valencia_log "${VALENCIA_LOG}" \
       --arg valencia_centroids_csv "${VALENCIA_CENTROIDS_CSV}" \
       --arg valencia_input_csv "${VALENCIA_INPUT_CSV}" \
       --arg valencia_output_csv "${VALENCIA_OUTPUT_CSV}" \
       --arg valencia_assignments_csv "${VALENCIA_ASSIGNMENTS_CSV}" \
       --arg valencia_plots_dir "${VALENCIA_PLOTS_DIR}" \
       '. + {
          valencia: {
            dir: $valencia_dir,
            log: $valencia_log,
            centroids_csv: ($valencia_centroids_csv | select(length>0) // null),
            input_csv: ($valencia_input_csv | select(length>0) // null),
            output_csv: ($valencia_output_csv | select(length>0) // null),
            assignments_csv: ($valencia_assignments_csv | select(length>0) // null),
            plots_dir: ($valencia_plots_dir | select(length>0) // null)
          }
        }' "${OUTPUTS_JSON}" > "${tmp}"
    mv "${tmp}" "${OUTPUTS_JSON}"
  fi
}

############################################
##          PYTHON / R SUMMARIES          ##
############################################

run_downstream_summaries_for_current_run() {
  local taxo_dir="${TAXO_ROOT}/${RUN_NAME}"
  local val_dir="${VALENCIA_RESULTS}"

  if [[ -n "${PY_SUMMARY_SCRIPT:-}" && "${PY_SUMMARY_SCRIPT}" != "null" && -f "${PY_SUMMARY_SCRIPT}" ]]; then
    log_info "Running Python summary script: ${PY_SUMMARY_SCRIPT}"
    python3 "${PY_SUMMARY_SCRIPT}" "${taxo_dir}" "${val_dir}" || log_warn "Python summary script failed (non-fatal)."
  else
    log_warn "Skipping Python summary script (not set or missing)."
  fi

  if [[ -n "${R_PLOT_SCRIPT:-}" && "${R_PLOT_SCRIPT}" != "null" && -f "${R_PLOT_SCRIPT}" ]]; then
    if command -v "${RSCRIPT_BIN}" >/dev/null 2>&1; then
      log_info "Running R plotting script: ${R_PLOT_SCRIPT}"
      "${RSCRIPT_BIN}" "${R_PLOT_SCRIPT}" "${taxo_dir}" "${val_dir}" || log_warn "R plotting script failed (non-fatal)."
    else
      log_warn "Skipping R plotting script (Rscript not found)."
    fi
  else
    log_warn "Skipping R plotting script (not set or missing)."
  fi
}

############################################
##      FASTQC + MULTIQC (existing module)##
############################################
# Keep the original "module-level" FastQC/MultiQC for FASTQ_SINGLE staged input as well,
# but for the long-read pipeline we run QC on per-barcode fastqs (qc_raw_per_barcode_fastq).
# So we keep the original block at the end, but it won't be used for the main flow unless you want it.

############################################
##         POSTPROCESS (embedded)         ##
############################################
# Generate summary tables and plots from kraken2 results (like sr_meta)

run_postprocess() {
  [[ "${POSTPROCESS_ENABLED}" == "1" ]] || { log_warn "Skipping postprocess (postprocess.enabled=0)"; return 0; }

  local taxo_run_dir="${TAXO_ROOT}/${RUN_NAME}"
  if [[ ! -d "${taxo_run_dir}" ]]; then
    log_warn "Skipping postprocess - no taxonomy results found at ${taxo_run_dir}"
    return 0
  fi

  local postprocess_dir="${RESULTS_DIR}/postprocess"
  local postprocess_log="${LOGS_DIR}/postprocess.log"
  local final_dir="${MODULE_OUT_DIR}/final"
  mkdir -p "${postprocess_dir}" "${final_dir}" "${final_dir}/plots" "${final_dir}/tables" "${LOGS_DIR}"

  python3 - "${taxo_run_dir}" "${postprocess_dir}" "${final_dir}" "${VALENCIA_RESULTS}" "${postprocess_log}" "${RUN_NAME}" <<'PY'
import os
import sys
import csv
import json
from pathlib import Path
from collections import defaultdict

taxo_run_dir = Path(sys.argv[1])
postprocess_dir = Path(sys.argv[2])
final_dir = Path(sys.argv[3])
valencia_dir = Path(sys.argv[4])
log_path = Path(sys.argv[5])
run_name = sys.argv[6]

def log(msg):
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(msg.rstrip() + "\n")
    print(msg)

log(f"[postprocess] Starting postprocessing for lr_meta run: {run_name}")

# Parse kraken2 reports
def parse_kreport(path):
    """Parse kraken2 report and return rows by rank."""
    rows_by_rank = defaultdict(list)
    total_reads = 0

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) < 6:
                continue
            try:
                pct = float(parts[0])
                clade_reads = int(parts[1])
                taxon_reads = int(parts[2])
                rank = parts[3].strip()
                taxid = parts[4].strip()
                name = parts[5].strip()

                if rank == "U":
                    continue
                if rank == "R":
                    total_reads = clade_reads
                    continue

                rows_by_rank[rank].append({
                    "taxid": taxid,
                    "name": name,
                    "clade_reads": clade_reads,
                    "taxon_reads": taxon_reads,
                    "pct": pct
                })
            except (ValueError, IndexError):
                continue

    return rows_by_rank, total_reads

# Find all kraken reports in per-barcode directories
reports = list(taxo_run_dir.glob("*/*.kreport"))
if not reports:
    log("[postprocess] No kraken2 reports found, skipping summarization")
    sys.exit(0)

log(f"[postprocess] Found {len(reports)} kraken2 report(s)")

# Process each report (prefer Bracken-corrected .breport when present)
all_species = []
all_genus = []

for report_path in reports:
    barcode = report_path.parent.name
    source_path = report_path
    breport_candidate = report_path.parent / f"{barcode}.breport"
    if breport_candidate.exists() and breport_candidate.stat().st_size > 0:
        source_path = breport_candidate
        log(f"[postprocess] Using Bracken-corrected report for {barcode}: {breport_candidate.name}")
    rows_by_rank, total_reads = parse_kreport(source_path)

    # Species level (S)
    for row in rows_by_rank.get("S", []):
        frac = row["clade_reads"] / total_reads if total_reads > 0 else 0
        all_species.append({
            "sample_id": barcode,
            "taxid": row["taxid"],
            "species": row["name"],
            "reads": row["clade_reads"],
            "fraction": frac
        })

    # Genus level (G)
    for row in rows_by_rank.get("G", []):
        frac = row["clade_reads"] / total_reads if total_reads > 0 else 0
        all_genus.append({
            "sample_id": barcode,
            "taxid": row["taxid"],
            "genus": row["name"],
            "reads": row["clade_reads"],
            "fraction": frac
        })

# Write tidy CSVs
def write_tidy_csv(path, rows, taxon_col):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["sample_id", "taxid", taxon_col, "reads", "fraction"])
        w.writeheader()
        for r in rows:
            w.writerow(r)

species_tidy = postprocess_dir / "kraken_species_tidy.csv"
genus_tidy = postprocess_dir / "kraken_genus_tidy.csv"

if all_species:
    write_tidy_csv(species_tidy, all_species, "species")
    log(f"[postprocess] Wrote species tidy CSV: {species_tidy}")

if all_genus:
    write_tidy_csv(genus_tidy, all_genus, "genus")
    log(f"[postprocess] Wrote genus tidy CSV: {genus_tidy}")

# NOTE: Plot generation is now handled by HOST-side R postprocessing
# This embedded Python section only generates tidy CSVs as input for the R scripts
# Plots will be generated by run_r_postprocess.sh after container execution completes
log("[postprocess] Tidy CSVs ready for HOST-side R postprocessing (plots will be generated there)")

# Copy key outputs to final directory
import shutil

# Copy kraken reports (and their Bracken-corrected .breport counterpart, if any)
for report in reports:
    dest_name = f"{report.parent.name}_{report.name}"
    shutil.copy2(report, final_dir / "tables" / dest_name)
    log(f"[postprocess] Copied {dest_name} to final/tables/")
    breport_candidate = report.parent / f"{report.parent.name}.breport"
    if breport_candidate.exists() and breport_candidate.stat().st_size > 0:
        breport_dest = f"{report.parent.name}_{breport_candidate.name}"
        shutil.copy2(breport_candidate, final_dir / "tables" / breport_dest)
        log(f"[postprocess] Copied {breport_dest} to final/tables/")

# Copy summary CSVs
if species_tidy.exists():
    shutil.copy2(species_tidy, final_dir / "tables" / "kraken_species_tidy.csv")
if genus_tidy.exists():
    shutil.copy2(genus_tidy, final_dir / "tables" / "kraken_genus_tidy.csv")

# Copy VALENCIA outputs if they exist
valencia_path = Path(valencia_dir)
if valencia_path.exists() and any(valencia_path.glob("*")):
    valencia_final = final_dir / "valencia"
    valencia_final.mkdir(exist_ok=True)

    for f in valencia_path.glob("*_valencia*.csv"):
        shutil.copy2(f, valencia_final / f.name)
        log(f"[postprocess] Copied VALENCIA: {f.name}")

    for f in valencia_path.glob("*.png"):
        shutil.copy2(f, valencia_final / f.name)
        log(f"[postprocess] Copied VALENCIA plot: {f.name}")

# Write manifest
tables_dir = final_dir / "tables"
plots_dir = final_dir / "plots"
valencia_final_dir = final_dir / "valencia"

manifest = {
    "module": "lr_meta",
    "run_name": run_name,
    "outputs": {
        "tables": sorted([f.name for f in tables_dir.glob("*")]) if tables_dir.exists() else [],
        "plots": sorted([f.name for f in plots_dir.glob("*.png")]) if plots_dir.exists() else [],
        "valencia": sorted([f.name for f in valencia_final_dir.glob("*")]) if valencia_final_dir.exists() else []
    }
}

manifest_path = final_dir / "manifest.json"
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
log(f"[postprocess] Wrote manifest: {manifest_path}")

log("[postprocess] Postprocessing complete!")
PY
}

############################################
##                 MAIN                   ##
############################################

main() {
  # Optional barcode mapping
  load_barcode_site_map "${SAMPLE_SHEET}"

  # Decide analysis mode
  if [[ "${INPUT_STYLE}" == "FAST5_DIR" || "${INPUT_STYLE}" == "FAST5" ]]; then
    # FAST5 -> basecall path
    # Step tracking handled manually below since we need to capture function output:
    local started ended ec msg

    started="$(iso_now)"
    log_info "FAST5 -> POD5"
    set +e
    pod5_path="$(convert_fast5_to_pod5)"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -eq 0 ]]; then
      steps_append "${STEPS_JSON}" "pod5" "succeeded" "pod5 conversion completed" "${POD5_BIN}" "${POD5_BIN} convert fast5 ..." "${ec}" "${started}" "${ended}"
    else
      steps_append "${STEPS_JSON}" "pod5" "failed" "pod5 conversion failed" "${POD5_BIN}" "${POD5_BIN} convert fast5 ..." "${ec}" "${started}" "${ended}"
      exit $ec
    fi

    started="$(iso_now)"
    log_info "Dorado basecalling -> BAM"
    set +e
    bam_path="$(dorado_basecall_to_bam "${pod5_path}")"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -eq 0 ]]; then
      steps_append "${STEPS_JSON}" "dorado_basecall" "succeeded" "dorado basecall completed" "${DORADO_BIN}" "${DORADO_BIN} basecaller ..." "${ec}" "${started}" "${ended}"
    else
      steps_append "${STEPS_JSON}" "dorado_basecall" "failed" "dorado basecall failed" "${DORADO_BIN}" "${DORADO_BIN} basecaller ..." "${ec}" "${started}" "${ended}"
      exit $ec
    fi

    started="$(iso_now)"
    log_info "Dorado demux -> per-barcode BAMs"
    set +e
    demux_dir="$(dorado_demux_to_per_barcode_bam "${bam_path}")"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -eq 0 ]]; then
      steps_append "${STEPS_JSON}" "dorado_demux" "succeeded" "dorado demux completed" "${DORADO_BIN}" "${DORADO_BIN} demux ..." "${ec}" "${started}" "${ended}"
    else
      steps_append "${STEPS_JSON}" "dorado_demux" "failed" "dorado demux failed" "${DORADO_BIN}" "${DORADO_BIN} demux ..." "${ec}" "${started}" "${ended}"
      exit $ec
    fi

    started="$(iso_now)"
    log_info "Dorado trim -> per-barcode FASTQ"
    set +e
    per_barcode_root="$(dorado_trim_bam_to_fastq_per_barcode "${demux_dir}")"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -eq 0 ]]; then
      steps_append "${STEPS_JSON}" "dorado_trim_fastq" "succeeded" "dorado trim + bam2fq completed" "${DORADO_BIN}" "${DORADO_BIN} trim ... + samtools bam2fq" "${ec}" "${started}" "${ended}"
    else
      steps_append "${STEPS_JSON}" "dorado_trim_fastq" "failed" "dorado trim + bam2fq failed" "${DORADO_BIN}" "${DORADO_BIN} trim ... + samtools bam2fq" "${ec}" "${started}" "${ended}"
      exit $ec
    fi

    PER_BARCODE_FASTQ_ROOT="${per_barcode_root}"
    ANALYSIS_FASTQ_MODE="per_barcode"

  elif [[ "${INPUT_STYLE}" == "BAM" ]]; then
    # BAM input - basecalled reads, skip basecalling
    log_info "BAM input detected - skipping basecalling, starting from demux/trim..."

    local bam_path="${STAGED_BAM}"
    local started ended ec

    # If barcode kit specified, demux first
    if [[ -n "${BARCODE_KIT}" && "${BARCODE_KIT}" != "null" ]]; then
      started="$(iso_now)"
      log_info "Dorado demux -> per-barcode BAMs"
      set +e
      demux_dir="$(dorado_demux_to_per_barcode_bam "${bam_path}")"
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -eq 0 ]]; then
        steps_append "${STEPS_JSON}" "dorado_demux" "succeeded" "dorado demux completed" "${DORADO_BIN}" "${DORADO_BIN} demux ..." "${ec}" "${started}" "${ended}"
      else
        steps_append "${STEPS_JSON}" "dorado_demux" "failed" "dorado demux failed" "${DORADO_BIN}" "${DORADO_BIN} demux ..." "${ec}" "${started}" "${ended}"
        exit $ec
      fi

      started="$(iso_now)"
      log_info "Dorado trim -> per-barcode FASTQ"
      set +e
      per_barcode_root="$(dorado_trim_bam_to_fastq_per_barcode "${demux_dir}")"
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -eq 0 ]]; then
        steps_append "${STEPS_JSON}" "dorado_trim_fastq" "succeeded" "dorado trim + bam2fq completed" "${DORADO_BIN}" "${DORADO_BIN} trim ... + samtools bam2fq" "${ec}" "${started}" "${ended}"
      else
        steps_append "${STEPS_JSON}" "dorado_trim_fastq" "failed" "dorado trim + bam2fq failed" "${DORADO_BIN}" "${DORADO_BIN} trim ... + samtools bam2fq" "${ec}" "${started}" "${ended}"
        exit $ec
      fi

      PER_BARCODE_FASTQ_ROOT="${per_barcode_root}"
    else
      # No barcode kit - treat as single sample, use configured name or run name
      local bam_single_name="${SINGLE_SAMPLE_NAME:-${RUN_NAME_BASE}}"
      log_info "No barcode kit specified - treating BAM as single sample (${bam_single_name})"
      make_dir "${TRIM_DIR}"
      make_dir "${RAW_READS_DIR}/${RUN_NAME}"

      local trimmed_bam="${TRIM_DIR}/${RUN_NAME}_trimmed.bam"
      local cmd=( "${DORADO_BIN}" trim "${bam_path}" )
      if [[ -n "${SEQUENCING_KIT:-}" && "${SEQUENCING_KIT}" != "null" ]]; then
        cmd+=( --sequencing-kit "${SEQUENCING_KIT}" )
      fi
      if [[ -n "${PRIMER_FASTA:-}" && "${PRIMER_FASTA}" != "null" && -s "${PRIMER_FASTA}" ]]; then
        cmd+=( --primer-sequences "${PRIMER_FASTA}" )
      fi

      started="$(iso_now)"
      set +e
      "${cmd[@]}" > "${trimmed_bam}"
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -eq 0 ]]; then
        steps_append "${STEPS_JSON}" "dorado_trim" "succeeded" "dorado trim completed" "${DORADO_BIN}" "dorado trim" "${ec}" "${started}" "${ended}"
      else
        steps_append "${STEPS_JSON}" "dorado_trim" "failed" "dorado trim failed" "${DORADO_BIN}" "dorado trim" "${ec}" "${started}" "${ended}"
        exit $ec
      fi

      # Convert to FASTQ
      local bcdir="${RAW_READS_DIR}/${RUN_NAME}/${bam_single_name}"
      make_dir "${bcdir}"
      local outfq="${bcdir}/${bam_single_name}.fastq"
      "${SAMTOOLS_BIN}" bam2fq "${trimmed_bam}" > "${outfq}"

      PER_BARCODE_FASTQ_ROOT="${RAW_READS_DIR}/${RUN_NAME}"
    fi

    ANALYSIS_FASTQ_MODE="per_barcode"

  elif [[ "${INPUT_STYLE}" == "FASTQ_SINGLE" ]]; then
    # FASTQs were already staged in per-barcode layout by the input resolution block above.
    # Each FASTQ's sample ID is its filename stem (or input.sample_name if configured).
    # No re-staging to barcode00 — the original name is preserved throughout the pipeline.
    PER_BARCODE_FASTQ_ROOT="${RAW_READS_DIR}/${RUN_NAME}"
    ANALYSIS_FASTQ_MODE="per_barcode"
    log_info "FASTQ_SINGLE: using pre-staged layout at ${PER_BARCODE_FASTQ_ROOT}"
  else
    die "Unsupported input style: ${INPUT_STYLE}"
  fi
  # QC on raw per-barcode fastqs (call function directly instead of through run_step)
  started="$(iso_now)"
  set +e
  qc_raw_per_barcode_fastq
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "raw_fastqc_multiqc" "succeeded" "raw fastqc + multiqc completed" "${FASTQC_BIN}" "fastqc + multiqc" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "raw_fastqc_multiqc" "skipped" "raw fastqc + multiqc skipped (error or tool missing)" "${FASTQC_BIN}" "fastqc + multiqc" "${ec}" "${started}" "${ended}"
    log_warn "FastQC/MultiQC step had issues (ec=$ec), continuing..."
  fi

  # Q-filter (optional)
  started="$(iso_now)"
  set +e
  qfilter_mean_q_per_barcode
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "qfilter" "succeeded" "qfilter completed or skipped" "${NANOFILT_BIN}" "NanoFilt" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "qfilter" "failed" "qfilter failed" "${NANOFILT_BIN}" "NanoFilt" "${ec}" "${started}" "${ended}"
    exit $ec
  fi

  # Human depletion (minimap2) — only runs if params.common.remove_host = 1/true
  if [[ "${REMOVE_HOST_NORM}" == "true" ]]; then
    started="$(iso_now)"
    set +e
    human_depletion_per_barcode
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -eq 0 ]]; then
      steps_append "${STEPS_JSON}" "host_depletion" "succeeded" "human depletion completed" "${MINIMAP2_BIN}" "minimap2 | samtools" "${ec}" "${started}" "${ended}"
    else
      steps_append "${STEPS_JSON}" "host_depletion" "failed" "human depletion failed" "${MINIMAP2_BIN}" "minimap2 | samtools" "${ec}" "${started}" "${ended}"
      exit $ec
    fi
  else
    # Host depletion disabled — symlink input reads into nonhuman/ dir as nonhuman.fastq.gz
    # so taxonomy_per_barcode_fixed_params finds the expected file names.
    local _ndir="${NONHUMAN_DIR}/${RUN_NAME_BASE}"
    shopt -s nullglob
    local _files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq \
                   "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz \
                   "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq \
                   "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz )
    for _f in "${_files[@]}"; do
      local _bc; _bc="$(basename "$(dirname "${_f}")")"
      make_dir "${_ndir}/${_bc}"
      if [[ "${_f}" == *.gz ]]; then
        ln -sf "${_f}" "${_ndir}/${_bc}/nonhuman.fastq.gz"
      else
        gzip -c "${_f}" > "${_ndir}/${_bc}/nonhuman.fastq.gz"
      fi
    done
    NONHUMAN_RUN_DIR="${_ndir}"
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "host_depletion" "skipped" "Host depletion disabled (params.common.remove_host != 1/true)" "" "" "0" "${started}" "${ended}"
    log_info "Host depletion disabled — reads symlinked to nonhuman dir for Kraken2."
  fi

  # Taxonomy
  started="$(iso_now)"
  set +e
  taxonomy_per_barcode_fixed_params
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "taxonomy" "succeeded" "kraken2 (+ krona/bracken optional) completed" "${KRAKEN2_BIN}" "kraken2" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "taxonomy" "failed" "taxonomy failed" "${KRAKEN2_BIN}" "kraken2" "${ec}" "${started}" "${ended}"
    exit $ec
  fi

  # VALENCIA (optional, mirroring sr_amp approach)
  run_valencia

  # Downstream summaries (optional)
  started="$(iso_now)"
  set +e
  run_downstream_summaries_for_current_run
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "summaries" "succeeded" "summaries completed or skipped" "python3/Rscript" "summary scripts" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "summaries" "failed" "summaries failed" "python3/Rscript" "summary scripts" "${ec}" "${started}" "${ended}"
    # non-fatal
  fi

  # Postprocess (embedded: generate tables + plots)
  local postprocess_dir="${RESULTS_DIR}/postprocess"
  local postprocess_log="${LOGS_DIR}/postprocess.log"
  local final_dir="${MODULE_OUT_DIR}/final"

  started="$(iso_now)"
  set +e
  run_postprocess
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "postprocess" "succeeded" "postprocess completed (tables + plots)" "python3" "python3 postprocess" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "postprocess" "failed" "postprocess failed" "python3" "python3 postprocess" "${ec}" "${started}" "${ended}"
    # non-fatal
  fi

  # Collect kraken2 report paths for output-check compatibility
  local taxo_run_dir="${TAXO_ROOT}/${RUN_NAME}"
  local kraken2_reports_json="[]"
  if [[ -d "${taxo_run_dir}" ]]; then
    shopt -s nullglob
    local kreport_files=( "${taxo_run_dir}"/*/*.kreport )
    shopt -u nullglob
    if [[ ${#kreport_files[@]} -gt 0 ]]; then
      kraken2_reports_json="$(printf '%s\n' "${kreport_files[@]}" | jq -R . | jq -s .)"
    fi
  fi

  # Attach paths to outputs.json (matches sr_meta structure for output-check compatibility)
  tmp="${OUTPUTS_JSON}.tmp"
  jq --arg steps_path "${STEPS_JSON}" \
     --arg results_dir "${RESULTS_DIR}" \
     --arg taxo_root "${TAXO_ROOT}" \
     --arg taxo_run_dir "${taxo_run_dir}" \
     --arg valencia_results "${VALENCIA_RESULTS}" \
     --arg nonhuman_dir "${NONHUMAN_RUN_DIR}" \
     --arg postprocess_dir "${postprocess_dir}" \
     --arg postprocess_log "${postprocess_log}" \
     --arg final_dir "${final_dir}" \
     --argjson kraken2_reports "${kraken2_reports_json}" \
     '. + {
        "steps_path":$steps_path,
        "results_dir":$results_dir,
        "taxonomy_root":$taxo_root,
        "taxonomy_run_dir":$taxo_run_dir,
        "kraken2": {
          "reports": $kraken2_reports,
          "results_dir": $taxo_run_dir
        },
        "valencia_results":$valencia_results,
        "nonhuman_dir":$nonhuman_dir,
        "postprocess":{"dir":$postprocess_dir, "log":$postprocess_log},
        "final_dir":$final_dir
      }' "${OUTPUTS_JSON}" > "${tmp}"
  mv "${tmp}" "${OUTPUTS_JSON}"

  log_done "PIPELINE COMPLETE ✅"
  log_done "Run: ${RUN_NAME}"
  log_done "Module out: ${MODULE_OUT_DIR}"
  log_done "Outputs: ${OUTPUTS_JSON}"
}

main "$@"

echo "[${MODULE_NAME}] Step staging complete"
print_step_status "${STEPS_JSON}" "raw_fastqc_multiqc"
print_step_status "${STEPS_JSON}" "qfilter"
print_step_status "${STEPS_JSON}" "host_depletion"
print_step_status "${STEPS_JSON}" "taxonomy"
print_step_status "${STEPS_JSON}" "valencia"
print_step_status "${STEPS_JSON}" "summaries"
print_step_status "${STEPS_JSON}" "postprocess"
echo "[${MODULE_NAME}] outputs.json: ${OUTPUTS_JSON}"
echo "[${MODULE_NAME}] final outputs: ${MODULE_OUT_DIR}/final"
