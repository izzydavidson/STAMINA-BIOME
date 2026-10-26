#!/usr/bin/env bash
set -euo pipefail

MODULE_NAME="lr_amp"

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
resolve_fastq_list() {
  local config_path="$1"
  local resolved=()

  local fastq_val
  fastq_val="$(jq -r '.input.fastq // .inputs.fastq // empty' "${config_path}" 2>/dev/null || true)"

  local fastqs_val
  fastqs_val="$(jq -r '.input.fastqs // .inputs.fastqs // empty' "${config_path}" 2>/dev/null || true)"

  local is_array
  is_array="$(jq -r 'if (.input.fastq // .inputs.fastq) | type == "array" then "yes" else "no" end' "${config_path}" 2>/dev/null || echo "no")"

  if [[ "${is_array}" == "yes" ]]; then
    while IFS= read -r path; do
      [[ -n "${path}" && "${path}" != "null" ]] || continue
      resolved+=("${path}")
    done < <(jq -r '(.input.fastq // .inputs.fastq) | .[]' "${config_path}" 2>/dev/null)
  elif [[ -n "${fastq_val}" && "${fastq_val}" != "null" ]]; then
    resolved+=("${fastq_val}")
  fi

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

  local final_files=()
  for entry in "${resolved[@]}"; do
    [[ -n "${entry}" ]] || continue

    if [[ -f "${entry}" ]]; then
      final_files+=("${entry}")
    elif [[ -d "${entry}" ]]; then
      while IFS= read -r f; do
        [[ -n "${f}" ]] && final_files+=("${f}")
      done < <(find "${entry}" -maxdepth 1 -type f \( -iname "*.fastq" -o -iname "*.fq" -o -iname "*.fastq.gz" -o -iname "*.fq.gz" \) | sort)
    elif [[ "${entry}" == *"*"* || "${entry}" == *"?"* || "${entry}" == *"["* ]]; then
      shopt -s nullglob
      local expanded=( ${entry} )
      shopt -u nullglob
      for f in "${expanded[@]}"; do
        [[ -f "${f}" ]] && final_files+=("${f}")
      done
    else
      final_files+=("${entry}")
    fi
  done

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
  if command -v exit_code_means_tool_missing >/dev/null 2>&1; then
    exit_code_means_tool_missing "$@"
    return $?
  fi
  local ec="${1:-0}"
  [[ "$ec" -eq 127 ]]
}

check_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
make_dir() { [[ -d "$1" ]] || { log_info "Creating: $1"; mkdir -p "$1"; }; }

############################################
##               CONFIG                   ##
############################################

INPUT_STYLE="$(jq_first "${CONFIG_PATH}" '.input.style' '.inputs.style' '.input_style' '.inputs.input_style' || true)"
[[ -n "${INPUT_STYLE}" ]] || INPUT_STYLE="FASTQ_SINGLE"

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

# Layout: <run_dir>/lr_amp/...
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
LENFILTER_DIR="${RESULTS_DIR}/lenfiltered"
TAXO_ROOT="${RESULTS_DIR}/taxonomy"
EMU_DIR="${RESULTS_DIR}/emu"
PRIMARY_TAXO_DIR="${RESULTS_DIR}/primary_taxonomy"
VALENCIA_TMP="${RESULTS_DIR}/valencia/tmp"
VALENCIA_RESULTS="${RESULTS_DIR}/valencia/results"

mkdir -p \
  "${FASTQ_STAGE_DIR}" "${FAST5_STAGE_DIR}" "${POD5_STAGE_DIR}" "${BAM_STAGE_DIR}" \
  "${DEMUX_DIR}" "${TRIM_DIR}" "${RAW_READS_DIR}" "${RAW_FASTQC_DIR}" "${RAW_MULTIQC_DIR}" \
  "${QFILTER_DIR}" "${LENFILTER_DIR}" \
  "${TAXO_ROOT}" "${EMU_DIR}" "${PRIMARY_TAXO_DIR}" \
  "${VALENCIA_TMP}" "${VALENCIA_RESULTS}"

RUN_NAME_BASE="$(jq_first "${CONFIG_PATH}" '.run.run_name' '.run.name' '.run_name' '.id' '.run_id' || true)"
[[ -n "${RUN_NAME_BASE}" ]] || RUN_NAME_BASE="$(date +%Y%m%d_%H%M%S)"
RUN_NAME="${RUN_NAME_BASE}"

SAMPLE_SHEET="$(jq_first "${CONFIG_PATH}" '.inputs.sample_sheet' '.input.sample_sheet' '.sample_sheet' '.barcode_sites_tsv' || true)"

THREADS="$(jq_first "${CONFIG_PATH}" '.resources.threads' '.run.threads' '.threads' || true)"
[[ -n "${THREADS}" ]] || THREADS="8"

# LR_AMP specific config: technology and amplicon type
TECHNOLOGY="$(jq_first "${CONFIG_PATH}" '.params.technology' '.technology' '.tools.technology' || true)"
[[ -n "${TECHNOLOGY}" ]] || TECHNOLOGY="ONT"
TECHNOLOGY="$(echo "${TECHNOLOGY}" | tr '[:lower:]' '[:upper:]')"

FULL_LENGTH="$(jq_first "${CONFIG_PATH}" '.params.full_length' '.full_length' '.amplicon.full_length' || true)"
[[ -n "${FULL_LENGTH}" ]] || FULL_LENGTH="1"

# Sequencing technology preset for Emu/minimap2 (map-ont, map-pb, map-hifi, lr:hq)
SEQ_TYPE="$(jq_first "${CONFIG_PATH}" '.params.seq_type' '.seq_type' '.tools.emu.type' || true)"
[[ -n "${SEQ_TYPE}" ]] || SEQ_TYPE="map-ont"
# Validate seq_type
case "${SEQ_TYPE}" in
  map-ont|map-pb|map-hifi|lr:hq) ;;
  *) log_warn "Invalid seq_type '${SEQ_TYPE}', defaulting to map-ont"; SEQ_TYPE="map-ont" ;;
esac

# Length filter settings for amplicons
# Full-length 16S: ~1500bp (1300-1700bp range)
# Partial/unknown: conservative wide window (200-900bp by default)
LEN_MIN_FULL="$(jq_first "${CONFIG_PATH}" '.params.len_min_full' '.amplicon.len_min_full' || true)"
[[ -n "${LEN_MIN_FULL}" ]] || LEN_MIN_FULL="1300"
LEN_MAX_FULL="$(jq_first "${CONFIG_PATH}" '.params.len_max_full' '.amplicon.len_max_full' || true)"
[[ -n "${LEN_MAX_FULL}" ]] || LEN_MAX_FULL="1700"
LEN_MIN_PARTIAL="$(jq_first "${CONFIG_PATH}" '.params.len_min_partial' '.amplicon.len_min_partial' || true)"
[[ -n "${LEN_MIN_PARTIAL}" ]] || LEN_MIN_PARTIAL="200"
LEN_MAX_PARTIAL="$(jq_first "${CONFIG_PATH}" '.params.len_max_partial' '.amplicon.len_max_partial' || true)"
[[ -n "${LEN_MAX_PARTIAL}" ]] || LEN_MAX_PARTIAL="900"

# Q-filter settings
QFILTER_ENABLED="$(jq_first "${CONFIG_PATH}" '.tools.qfilter.enabled' '.qfilter.enabled' '.qfilter_enabled' || true)"
[[ -n "${QFILTER_ENABLED}" ]] || QFILTER_ENABLED="1"
QFILTER_MIN_Q="$(jq_first "${CONFIG_PATH}" '.tools.qfilter.min_q' '.qfilter.min_q' '.qfilter_min_q' || true)"
[[ -n "${QFILTER_MIN_Q}" ]] || QFILTER_MIN_Q="10"

# VALENCIA config (mirroring sr_amp approach)
VALENCIA_ENABLED_RAW="$(jq_first "${CONFIG_PATH}" '.valencia.enabled' '.tools.valencia.enabled' '.valencia_enabled' || true)"
VALENCIA_CENTROIDS_CSV="$(jq_first "${CONFIG_PATH}" '.valencia.centroids_csv' '.tools.valencia.centroids_csv' || true)"
LR_AMP_SAMPLE_TYPE_RAW="$(jq_first "${CONFIG_PATH}" '.sample_type' '.input.sample_type' '.inputs.sample_type' '.run.sample_type' '.run.sample_type_resolved' || true)"

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

LR_AMP_SAMPLE_TYPE_NORM="$(printf "%s" "${LR_AMP_SAMPLE_TYPE_RAW}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

POSTPROCESS_ENABLED="$(jq_first "${CONFIG_PATH}" '.postprocess.enabled' '.tools.postprocess.enabled' '.postprocess_enabled' || true)"
[[ -n "${POSTPROCESS_ENABLED}" ]] || POSTPROCESS_ENABLED="1"

# References + DB
KRAKEN2_DB="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.db' '.tools.kraken2.db_classify' '.kraken2_db' || true)"

# Emu settings
EMU_DB="$(jq_first "${CONFIG_PATH}" '.tools.emu.db' '.emu.db' '.emu_db' || true)"
EMU_MIN_PID="$(jq_first "${CONFIG_PATH}" '.tools.emu.min_pid' '.emu.min_pid' '.emu_min_pid' || true)"
[[ -n "${EMU_MIN_PID}" ]] || EMU_MIN_PID="95"

# Kraken params for amplicon
KRAKEN_CONF_VAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.vaginal.confidence' '.kraken_confidence_vaginal' || true)"
[[ -n "${KRAKEN_CONF_VAGINAL}" ]] || KRAKEN_CONF_VAGINAL="0.1"
KRAKEN_MHG_VAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.vaginal.minimum_hit_groups' '.kraken_min_hit_groups_vaginal' || true)"
[[ -n "${KRAKEN_MHG_VAGINAL}" ]] || KRAKEN_MHG_VAGINAL="2"

KRAKEN_CONF_NONVAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.nonvaginal.confidence' '.kraken_confidence_nonvaginal' || true)"
[[ -n "${KRAKEN_CONF_NONVAGINAL}" ]] || KRAKEN_CONF_NONVAGINAL="0.05"
KRAKEN_MHG_NONVAGINAL="$(jq_first "${CONFIG_PATH}" '.tools.kraken2.nonvaginal.minimum_hit_groups' '.kraken_min_hit_groups_nonvaginal' || true)"
[[ -n "${KRAKEN_MHG_NONVAGINAL}" ]] || KRAKEN_MHG_NONVAGINAL="2"

USE_BRACKEN="$(jq_first "${CONFIG_PATH}" '.tools.bracken.enabled' '.use_bracken' || true)"
[[ -n "${USE_BRACKEN}" ]] || USE_BRACKEN="1"
BRACKEN_READLEN="$(jq_first "${CONFIG_PATH}" '.tools.bracken.readlen' '.bracken_readlen' || true)"
[[ -n "${BRACKEN_READLEN}" ]] || BRACKEN_READLEN="1500"
BRACKEN_AVAILABLE="1"

# Dorado/Pod5 settings (used when FAST5 input is provided)
DORADO_MODEL="$(jq_first "${CONFIG_PATH}" '.tools.dorado.model' '.dorado.model' || true)"
LIGATION_KIT="$(jq_first "${CONFIG_PATH}" '.tools.dorado.ligation_kit' '.dorado.ligation_kit' || true)"
BARCODE_KIT="$(jq_first "${CONFIG_PATH}" '.tools.dorado.barcode_kit' '.dorado.barcode_kit' || true)"
SEQUENCING_KIT="$(jq_first "${CONFIG_PATH}" '.tools.dorado.sequencing_kit' '.dorado.sequencing_kit' || true)"
PRIMER_FASTA="$(jq_first "${CONFIG_PATH}" '.tools.dorado.primer_fasta' '.dorado.primer_fasta' || true)"

############################################
##   INPUT RESOLUTION + STAGING           ##
############################################

STAGED_FASTQ=""
STAGED_FAST5_DIR=""
PER_BARCODE_FASTQ_ROOT=""

case "${INPUT_STYLE}" in
  FASTQ_SINGLE)
    HAS_R1="$(jq -r '.input.fastq_r1 // .inputs.fastq_r1 // empty' "${CONFIG_PATH}" 2>/dev/null || true)"
    HAS_R2="$(jq -r '.input.fastq_r2 // .inputs.fastq_r2 // empty' "${CONFIG_PATH}" 2>/dev/null || true)"
    if [[ -n "${HAS_R1}" || -n "${HAS_R2}" ]]; then
      log_warn "Long-read pipeline detected R1/R2 FASTQ config keys. These are ignored."
      log_warn "Long-read sequencing produces single-end reads only. Using .input.fastq instead."
    fi

    FASTQ_LIST_RAW="$(resolve_fastq_list "${CONFIG_PATH}")"

    FASTQ_FILES=()
    while IFS= read -r fq_path; do
      [[ -n "${fq_path}" ]] && FASTQ_FILES+=("${fq_path}")
    done <<< "${FASTQ_LIST_RAW}"

    if [[ ${#FASTQ_FILES[@]} -eq 0 ]]; then
      echo "ERROR: FASTQ_SINGLE selected but could not resolve any FASTQ file(s) from config." >&2
      exit 2
    fi

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
      exit 2
    fi

    log_info "Staging ${#FASTQ_FILES[@]} FASTQ(s) into per-barcode layout..."
    STAGED_FASTQS=()
    BARCODE_IDS=()

    for fq in "${FASTQ_FILES[@]}"; do
      basename_full="$(basename "${fq}")"
      barcode_id="${basename_full%.fastq.gz}"
      barcode_id="${barcode_id%.fastq}"
      barcode_id="${barcode_id%.fq.gz}"
      barcode_id="${barcode_id%.fq}"

      barcode_dir="${RAW_READS_DIR}/${RUN_NAME}/${barcode_id}"
      make_dir "${barcode_dir}"

      if [[ "${fq}" == *.gz ]]; then
        staged_path="${barcode_dir}/${barcode_id}.fastq.gz"
      else
        staged_path="${barcode_dir}/${barcode_id}.fastq"
      fi

      ln -sfn "$(realpath "${fq}")" "${staged_path}" 2>/dev/null || cp "${fq}" "${staged_path}"
      STAGED_FASTQS+=("${staged_path}")
      BARCODE_IDS+=("${barcode_id}")
    done

    PER_BARCODE_FASTQ_ROOT="${RAW_READS_DIR}/${RUN_NAME}"
    log_info "Staged ${#STAGED_FASTQS[@]} FASTQ(s) to: ${PER_BARCODE_FASTQ_ROOT}"
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
    echo "ERROR: Unsupported input style: ${INPUT_STYLE}. lr_amp supports FASTQ_SINGLE, FAST5_DIR, or BAM." >&2
    exit 2
    ;;
esac

OUTPUTS_JSON="${MODULE_OUT_DIR}/outputs.json"

# Build outputs.json based on input style
if [[ "${INPUT_STYLE}" == "FASTQ_SINGLE" ]]; then
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
    --arg technology "${TECHNOLOGY}" \
    --argjson full_length "${FULL_LENGTH}" \
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
      "technology": $technology,
      "full_length": $full_length,
      "inputs": {
        "fastq": $fastq,
        "fastq_list": $fastq_list,
        "barcode_ids": $barcode_ids,
        "per_barcode_root": $per_barcode_root,
        "sample_count": ($fastq_list | length)
      }
    }' > "${OUTPUTS_JSON}"
else
  # FAST5_DIR or FAST5 input style
  jq -n \
    --arg module_name "${MODULE_NAME}" \
    --arg pipeline_id "${PIPELINE_ID:-}" \
    --arg run_id "${RUN_ID:-}" \
    --arg input_style "${INPUT_STYLE}" \
    --arg technology "${TECHNOLOGY}" \
    --argjson full_length "${FULL_LENGTH}" \
    --arg fast5_dir "${STAGED_FAST5_DIR}" \
    '{
      "module": $module_name,
      "pipeline_id": $pipeline_id,
      "run_id": $run_id,
      "run_name": "'"${RUN_NAME}"'",
      "input_style": $input_style,
      "technology": $technology,
      "full_length": $full_length,
      "inputs": { "fast5_dir": $fast5_dir }
    }' > "${OUTPUTS_JSON}"
fi

############################################
##              METRICS                   ##
############################################
METRICS_JSON="${MODULE_OUT_DIR}/metrics.json"

if [[ "${INPUT_STYLE}" == "FASTQ_SINGLE" ]]; then
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
    --arg note "metrics calculated after basecalling (input_style is FAST5)" \
    '{ "module": $module_name, "note": $note }' > "${METRICS_JSON}"
fi

tmp="${OUTPUTS_JSON}.tmp"
jq --arg metrics_path "${METRICS_JSON}" --slurpfile metrics "${METRICS_JSON}" \
  '. + {"metrics_path":$metrics_path, "metrics":$metrics[0]}' "${OUTPUTS_JSON}" > "${tmp}"
mv "${tmp}" "${OUTPUTS_JSON}"

############################################
##     TOOL RESOLUTION (config-aware)     ##
############################################

POD5_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.pod5_bin' 'pod5')"
DORADO_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.dorado_bin' 'dorado')"
SAMTOOLS_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.samtools_bin' 'samtools')"
FASTQC_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.fastqc_bin' 'fastqc')"
MULTIQC_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.multiqc_bin' 'multiqc')"
NANOFILT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.nanofilt_bin' 'NanoFilt')"
KRAKEN2_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.kraken2.bin' 'kraken2')"
BRACKEN_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.bracken.bin' 'bracken')"
EMU_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.emu.bin' 'emu')"
GIT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.git_bin' 'git')"
RSCRIPT_BIN="$(resolve_tool "${CONFIG_PATH}" '.tools.rscript_bin' 'Rscript')"

############################################
##     BARCODE SITE MAPPING               ##
############################################
SAMPLE_TYPE_RAW="$(jq_first "${CONFIG_PATH}" '.input.sample_type' '.specimen' '.sample_type' '.inputs.sample_type' '.run.sample_type' || true)"
SAMPLE_TYPE_NORM="$(printf "%s" "${SAMPLE_TYPE_RAW:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
[[ -n "${SAMPLE_TYPE_NORM}" ]] || SAMPLE_TYPE_NORM="unknown"

declare -A SITE_BY_BARCODE
declare -A NAME_BY_BARCODE

load_barcode_site_map() {
  local sheet="${1:-}"
  SITE_BY_BARCODE=()
  NAME_BY_BARCODE=()

  if [[ "${INPUT_STYLE}" == "FASTQ_SINGLE" && -n "${SAMPLE_TYPE_NORM}" && "${SAMPLE_TYPE_NORM}" != "unknown" ]]; then
    log_info "Using input.sample_type='${SAMPLE_TYPE_RAW}' for all samples"
    for bc in "${BARCODE_IDS[@]}"; do
      SITE_BY_BARCODE["${bc}"]="${SAMPLE_TYPE_NORM}"
    done
  fi

  if [[ -z "${sheet}" || "${sheet}" == "null" ]]; then
    log_info "No sample sheet provided; using config sample_type for all barcodes."
    return 0
  fi

  if [[ ! -f "${sheet}" ]]; then
    log_warn "Sample sheet not found: ${sheet}; using config sample_type."
    return 0
  fi

  log_info "Loading barcode site map from: ${sheet}"
  while IFS=$'\t' read -r barcode site rest; do
    [[ -z "${barcode}" || "${barcode}" == "barcode" ]] && continue
    barcode="$(echo "${barcode}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    site="$(echo "${site}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    SITE_BY_BARCODE["${barcode}"]="${site}"
  done < "${sheet}"

  log_info "Loaded site mapping for ${#SITE_BY_BARCODE[@]} barcodes"
}

is_vaginal_barcode() {
  local barcode="${1:-}"
  local site="${SITE_BY_BARCODE[${barcode}]:-unknown}"
  [[ "${site}" == "vaginal" || "${site}" == "vag" || "${site}" == "v" ]]
}

get_site_for_barcode() {
  local barcode="${1:-}"
  echo "${SITE_BY_BARCODE[${barcode}]:-unknown}"
}

check_bracken_available() {
  if ! command -v "${BRACKEN_BIN}" >/dev/null 2>&1; then
    BRACKEN_AVAILABLE="0"
    USE_BRACKEN="0"
    log_warn "Bracken not found. Bracken will be skipped."
    return 0
  fi

  [[ -n "${KRAKEN2_DB}" && "${KRAKEN2_DB}" != "null" ]] || { BRACKEN_AVAILABLE="0"; USE_BRACKEN="0"; log_warn "KRAKEN2_DB not set; bracken disabled."; return 0; }
  local kmer_file="${KRAKEN2_DB}/database${BRACKEN_READLEN}mers.kmer_distrib"
  if [[ ! -s "${kmer_file}" ]]; then
    BRACKEN_AVAILABLE="0"
    USE_BRACKEN="0"
    log_warn "Bracken kmer distribution not found at ${kmer_file}; bracken disabled."
  fi
}

############################################
##     DORADO BASECALLING FLOW            ##
## (Used when INPUT_STYLE is FAST5_DIR)   ##
############################################

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
  local model_dir="${DORADO_MODEL_DIR:-/dorado_models}"
  mkdir -p "${model_dir}"

  log_info "Using Dorado model: ${DORADO_MODEL}"
  log_info "Downloading model if not cached (this may take a while on first run)..."

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
    log_warn "barcode_kit empty; treating as single sample 'barcode00'"
    cp "${inbam}" "${outdir}/barcode00.bam"
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
  if ! command -v "${FASTQC_BIN}" >/dev/null 2>&1; then
    log_warn "FastQC not found - skipping QC step"
    return 0
  fi

  make_dir "${RAW_FASTQC_DIR}"
  make_dir "${RAW_MULTIQC_DIR}"

  shopt -s nullglob
  local files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz )
  [[ ${#files[@]} -gt 0 ]] || { log_warn "No per-barcode FASTQ files found for QC"; return 0; }

  for fq in "${files[@]}"; do
    log "FastQC on ${fq}"
    "${FASTQC_BIN}" -t "${THREADS}" -o "${RAW_FASTQC_DIR}" "${fq}" || log_warn "FastQC failed for ${fq}"
  done

  if command -v "${MULTIQC_BIN}" >/dev/null 2>&1; then
    "${MULTIQC_BIN}" "${RAW_FASTQC_DIR}" -o "${RAW_MULTIQC_DIR}" || log_warn "MultiQC failed"
  fi
}

############################################
##   Q-FILTER (NanoFilt, MEAN Q >= X)     ##
############################################

qfilter_mean_q_per_barcode() {
  [[ "${QFILTER_ENABLED}" == "1" ]] || { log_warn "Skipping Q-filter (qfilter.enabled=0)"; return 0; }

  if ! command -v "${NANOFILT_BIN}" >/dev/null 2>&1; then
    log_warn "Skipping Q-filter (NanoFilt not found)"
    return 0
  fi

  local out_root="${QFILTER_DIR}/${RUN_NAME_BASE}"
  make_dir "${out_root}"

  shopt -s nullglob
  local files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz )
  [[ ${#files[@]} -gt 0 ]] || { log_warn "No FASTQ files found for Q-filter"; return 0; }

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
##   LENGTH FILTER (AMPLICON-SPECIFIC)    ##
############################################

length_filter_per_barcode() {
  local min_len max_len
  if [[ "${FULL_LENGTH}" == "1" ]]; then
    min_len="${LEN_MIN_FULL}"
    max_len="${LEN_MAX_FULL}"
    log_info "Applying full-length 16S length filter: ${min_len}-${max_len}bp"
  else
    min_len="${LEN_MIN_PARTIAL}"
    max_len="${LEN_MAX_PARTIAL}"
    log_info "Applying partial amplicon length filter: ${min_len}-${max_len}bp"
  fi

  if ! command -v "${NANOFILT_BIN}" >/dev/null 2>&1; then
    log_warn "Skipping length filter (NanoFilt not found)"
    return 0
  fi

  local out_root="${LENFILTER_DIR}/${RUN_NAME_BASE}"
  make_dir "${out_root}"

  shopt -s nullglob
  local files=( "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fastq "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq.gz "${PER_BARCODE_FASTQ_ROOT}"/*/*.fq )
  [[ ${#files[@]} -gt 0 ]] || { log_warn "No FASTQ files found for length filter"; return 0; }

  for fq in "${files[@]}"; do
    local barcode
    barcode="$(basename "$(dirname "${fq}")")"

    make_dir "${out_root}/${barcode}"
    local out_fq="${out_root}/${barcode}/${barcode}.len${min_len}-${max_len}.fastq.gz"

    log "Length filter: ${fq} -> ${out_fq}"
    if [[ "${fq}" == *.gz ]]; then
      gzip -cd "${fq}" | "${NANOFILT_BIN}" -l "${min_len}" --maxlength "${max_len}" | gzip -c > "${out_fq}"
    else
      "${NANOFILT_BIN}" -l "${min_len}" --maxlength "${max_len}" < "${fq}" | gzip -c > "${out_fq}"
    fi
  done

  PER_BARCODE_FASTQ_ROOT="${out_root}"
}

############################################
##  PRIMARY CLASSIFICATION (EMU/ASV)      ##
############################################

emu_classification_per_barcode() {
  # lr_amp uses ONLY Emu for classification (no Kraken2)
  if [[ "${FULL_LENGTH}" != "1" ]]; then
    log_warn "Skipping Emu (not full-length amplicons). Note: lr_amp uses Emu only."
    return 0
  fi

  if ! command -v "${EMU_BIN}" >/dev/null 2>&1; then
    log_fail "Emu not found - lr_amp requires Emu for classification"
    return 1
  fi

  if [[ -z "${EMU_DB}" || "${EMU_DB}" == "null" ]]; then
    log_fail "EMU_DB not set - lr_amp requires Emu database"
    return 1
  fi

  log_info "Using sequencing technology preset: ${SEQ_TYPE}"

  local emu_run_dir="${EMU_DIR}/${RUN_NAME}"
  make_dir "${emu_run_dir}"

  local input_dir="${PER_BARCODE_FASTQ_ROOT}"

  shopt -s nullglob
  local fqs=( "${input_dir}"/*/*.fastq.gz "${input_dir}"/*/*.fastq "${input_dir}"/*/*.fq.gz "${input_dir}"/*/*.fq )
  [[ ${#fqs[@]} -gt 0 ]] || { log_warn "No FASTQ files found for Emu classification"; return 0; }

  for fq in "${fqs[@]}"; do
    local barcode
    barcode="$(basename "$(dirname "${fq}")")"

    local out_dir="${emu_run_dir}/${barcode}"
    make_dir "${out_dir}"

    log "Emu classification (--type ${SEQ_TYPE} --min-pid ${EMU_MIN_PID}): ${fq}"
    "${EMU_BIN}" abundance \
      --db "${EMU_DB}" \
      --type "${SEQ_TYPE}" \
      --threads "${THREADS}" \
      --K 100000000 \
      --min-pid "${EMU_MIN_PID}" \
      --output-dir "${out_dir}" \
      "${fq}" || log_warn "Emu failed for ${barcode}"
  done

  log_info "Emu classification complete: ${emu_run_dir}"
}

############################################
##  KRAKEN2 - DISABLED FOR lr_amp        ##
##  (lr_amp uses ONLY Emu classification) ##
############################################

kraken2_secondary_per_barcode() {
  # lr_amp uses ONLY Emu for taxonomy classification
  # Kraken2/Bracken are disabled - use lr_meta for Kraken2-based workflows
  log_info "Kraken2 disabled for lr_amp (Emu-only pipeline)"
  return 0
}

############################################
##       VALENCIA (vaginal samples)       ##
############################################

# VALENCIA runs inline Python (no external Valencia.py dependency)
# This mirrors the sr_amp approach for consistency across all pipelines

run_valencia() {
  # lr_amp uses Emu outputs for VALENCIA (not Kraken2 kreports)
  local emu_run_dir="${EMU_DIR}/${RUN_NAME}"

  # Determine if VALENCIA should run
  VALENCIA_SHOULD_RUN="no"
  if [[ "${VALENCIA_ENABLED}" == "true" ]]; then
    VALENCIA_SHOULD_RUN="yes"
  elif [[ "${VALENCIA_ENABLED}" == "auto" ]]; then
    if [[ "${LR_AMP_SAMPLE_TYPE_NORM}" == "vaginal" ]]; then
      VALENCIA_SHOULD_RUN="yes"
    fi
  fi

  if [[ "${VALENCIA_SHOULD_RUN}" != "yes" ]]; then
    local started ended
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "valencia" "skipped" "VALENCIA skipped (enabled=${VALENCIA_ENABLED}, sample_type=${LR_AMP_SAMPLE_TYPE_RAW:-})" "" "" "0" "${started}" "${ended}"
    return 0
  fi

  # Check for Emu output files (not kreports - lr_amp is Emu-only)
  if [[ ! -d "${emu_run_dir}" ]]; then
    local started ended
    started="$(iso_now)"; ended="$(iso_now)"
    steps_append "${STEPS_JSON}" "valencia" "skipped" "VALENCIA skipped - no Emu results at ${emu_run_dir}" "" "" "0" "${started}" "${ended}"
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

  VALENCIA_INPUT_CSV="${VALENCIA_DIR}/taxon_table_emu.csv"
  VALENCIA_OUTPUT_CSV="${VALENCIA_DIR}/output.csv"
  VALENCIA_ASSIGNMENTS_CSV="${VALENCIA_DIR}/valencia_assignments.csv"

  log_info "Running VALENCIA classification (from Emu outputs)..."
  log_info "  Centroids: ${VALENCIA_CENTROIDS_CSV}"
  log_info "  Emu dir: ${emu_run_dir}"

  local started ended ec
  started="$(iso_now)"
  set +e
  python3 - "${VALENCIA_CENTROIDS_CSV}" "${emu_run_dir}" "${VALENCIA_DIR}" "${VALENCIA_PLOTS_DIR}" >>"${VALENCIA_LOG}" 2>&1 <<'VALENCIA_PY'
import sys, os, re, csv, math
from pathlib import Path

centroids_csv, emu_run_dir, out_dir, plots_dir = sys.argv[1:]
os.makedirs(out_dir, exist_ok=True)
os.makedirs(plots_dir, exist_ok=True)

# -----------------------------
# Helpers: taxa name normalization (match VALENCIA centroids format)
# -----------------------------
bc_focal = {'Lactobacillus','Prevotella','Gardnerella','Atopobium','Sneathia'}

def norm_taxa_name(name: str) -> str:
    """Normalize taxa name to match VALENCIA centroids format."""
    name = (name or "").strip()
    name = name.lstrip()
    name = name.replace(" ", "_")
    return name

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
# Parse Emu rel-abundance TSV files
# -----------------------------
def parse_emu_abundance(path: str):
    """Parse Emu relative abundance TSV, return dict of taxa -> abundance (fraction)."""
    taxa_abundance = {}
    total_abundance = 0.0

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter='\t')
        for row in reader:
            # Emu TSV columns: tax_id, abundance, species, genus, family, ...
            abundance_str = row.get("abundance", "0")
            species = row.get("species", "").strip()
            genus = row.get("genus", "").strip()

            try:
                abundance = float(abundance_str)
            except (ValueError, TypeError):
                continue

            if abundance <= 0:
                continue

            # Build taxa name for VALENCIA matching
            # Prefer species if available, otherwise use genus
            if species and species.lower() not in ("", "nan", "none"):
                # Format: Genus_species
                if genus and genus.lower() not in ("", "nan", "none"):
                    taxa_name = f"{genus}_{species}".replace(" ", "_")
                else:
                    taxa_name = species.replace(" ", "_")
            elif genus and genus.lower() not in ("", "nan", "none"):
                taxa_name = f"g_{genus}".replace(" ", "_")
            else:
                continue

            taxa_name = norm_taxa_name(taxa_name)
            taxa_abundance[taxa_name] = taxa_abundance.get(taxa_name, 0.0) + abundance
            total_abundance += abundance

    return taxa_abundance, total_abundance

# Find all Emu rel-abundance TSV files
emu_path = Path(emu_run_dir)
emu_files = list(emu_path.glob("*/*_rel-abundance.tsv"))

if not emu_files:
    print(f"WARNING: No Emu rel-abundance files found in {emu_run_dir}")
    sys.exit(0)

print(f"Found {len(emu_files)} Emu abundance file(s)")

# Build sample data from Emu outputs
samples_data = []
all_taxa = set()

for emu_file in emu_files:
    sample_id = emu_file.parent.name
    taxa_abundance, total_abundance = parse_emu_abundance(emu_file)

    if not taxa_abundance:
        print(f"  Skipping {sample_id}: no taxa found")
        continue

    samples_data.append({
        "sample_id": sample_id,
        "taxa_abundance": taxa_abundance,
        "total_abundance": total_abundance
    })
    all_taxa.update(taxa_abundance.keys())
    print(f"  Parsed {sample_id}: {len(taxa_abundance)} taxa, total_abund={total_abundance:.4f}")

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

    if "sub_CST" not in fields and "subCST" in fields:
        fields = ["sub_CST" if x == "subCST" else x for x in fields]

    if "sub_CST" not in fields:
        raise SystemExit("ERROR: centroids CSV missing 'sub_CST' column")

    for row in reader:
        centroid_rows.append(row)

if not centroid_rows:
    raise SystemExit("ERROR: centroids CSV has no rows")

ignore_cols = {"sampleID", "read_count", "sub_CST", "subCST"}
centroid_taxa_cols = [c for c in centroid_rows[0].keys() if c not in ignore_cols]

print(f"Loaded {len(centroid_rows)} centroids with {len(centroid_taxa_cols)} taxa columns")

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

CSTs = ['I-A','I-B','II','III-A','III-B','IV-A','IV-B','IV-C0','IV-C1','IV-C2','IV-C3','IV-C4','V']

# -----------------------------
# Build taxa mapping from Emu names to centroid names
# -----------------------------
def normalize_for_matching(s: str) -> str:
    s = (s or "").strip().lower()
    s = s.replace(" ", "_").replace("-", "_").replace(".", "_")
    s = re.sub(r"[^a-z0-9_]", "", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s

centroid_taxa_norm = {normalize_for_matching(t): t for t in centroid_taxa_cols}

# -----------------------------
# Write input CSV (sample x taxa abundances)
# -----------------------------
taxon_table_csv = os.path.join(out_dir, "taxon_table_emu.csv")

with open(taxon_table_csv, "w", encoding="utf-8", newline="") as out:
    w = csv.writer(out)
    w.writerow(["sampleID", "total_abundance", *centroid_taxa_cols])

    for sample in samples_data:
        sid = sample["sample_id"]
        total = sample["total_abundance"]
        taxa_abundance = sample["taxa_abundance"]

        row_abund = {t: 0.0 for t in centroid_taxa_cols}
        for emu_taxa, abund in taxa_abundance.items():
            emu_norm = normalize_for_matching(emu_taxa)
            if emu_norm in centroid_taxa_norm:
                canonical = centroid_taxa_norm[emu_norm]
                row_abund[canonical] += abund

        row = [sid, f"{total:.6f}"]
        row.extend([f"{row_abund.get(t, 0.0):.6f}" for t in centroid_taxa_cols])
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
    total = sample["total_abundance"]
    taxa_abundance = sample["taxa_abundance"]

    row_abund = {t: 0.0 for t in centroid_taxa_cols}
    for emu_taxa, abund in taxa_abundance.items():
        emu_norm = normalize_for_matching(emu_taxa)
        if emu_norm in centroid_taxa_norm:
            canonical = centroid_taxa_norm[emu_norm]
            row_abund[canonical] += abund

    # Build observation vector (already relative abundances from Emu)
    obs_vec = []
    total_matched = sum(row_abund.values())
    if total_matched > 0:
        for t in centroid_taxa_cols:
            obs_vec.append(float(row_abund.get(t, 0.0)) / float(total_matched))
    else:
        obs_vec = [0.0 for _ in centroid_taxa_cols]

    sims = {}
    for cst in CSTs:
        if cst in centroids:
            sims[cst] = yue_similarity(obs_vec, centroids[cst])
        else:
            sims[cst] = float("nan")

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

    cst_group = subcst
    if subcst in ("I-A", "I-B"):
        cst_group = "I"
    elif subcst in ("III-A", "III-B"):
        cst_group = "III"
    elif subcst in ("IV-C0", "IV-C1", "IV-C2", "IV-C3", "IV-C4"):
        cst_group = "IV-C"

    out_row = {"sampleID": sid, "total_abundance": f"{total:.6f}"}
    for t in centroid_taxa_cols:
        out_row[t] = f"{row_abund.get(t, 0.0):.6f}"
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
    fieldnames = ["sampleID", "total_abundance", *centroid_taxa_cols, *sim_cols, "subCST", "score", "CST"]
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
##         POSTPROCESS (embedded)         ##
############################################

run_postprocess() {
  [[ "${POSTPROCESS_ENABLED}" == "1" ]] || { log_warn "Skipping postprocess (postprocess.enabled=0)"; return 0; }

  # lr_amp uses ONLY Emu - check for Emu outputs (not Kraken2)
  local emu_run_dir="${EMU_DIR}/${RUN_NAME}"
  if [[ ! -d "${emu_run_dir}" ]]; then
    log_warn "Skipping postprocess - no Emu results found at ${emu_run_dir}"
    return 0
  fi

  local postprocess_dir="${RESULTS_DIR}/postprocess"
  local postprocess_log="${LOGS_DIR}/postprocess.log"
  local final_dir="${MODULE_OUT_DIR}/final"
  mkdir -p "${postprocess_dir}" "${final_dir}" "${final_dir}/plots" "${final_dir}/tables" "${final_dir}/valencia"

  python3 - "${emu_run_dir}" "${postprocess_dir}" "${final_dir}" "${VALENCIA_DIR:-}" "${postprocess_log}" "${RUN_NAME}" "${MODULE_NAME}" <<'PY'
import os
import sys
import csv
import json
import shutil
from pathlib import Path
from collections import defaultdict

emu_dir = Path(sys.argv[1])
postprocess_dir = Path(sys.argv[2])
final_dir = Path(sys.argv[3])
valencia_dir_str = sys.argv[4]
valencia_dir = Path(valencia_dir_str) if valencia_dir_str else None
log_path = Path(sys.argv[5])
run_name = sys.argv[6]
module_name = sys.argv[7]

def log(msg):
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(msg.rstrip() + "\n")
    print(msg)

log(f"[postprocess] Starting postprocessing for {module_name} run: {run_name}")
log(f"[postprocess] lr_amp uses Emu-only (no Kraken2)")

# Parse Emu rel-abundance TSV files
def parse_emu_abundance(path):
    """Parse Emu TSV file and return species/genus data."""
    species_data = []
    genus_data = []

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter='\t')
        for row in reader:
            try:
                abundance = float(row.get("abundance", 0))
            except (ValueError, TypeError):
                continue

            if abundance <= 0:
                continue

            tax_id = row.get("tax_id", "")
            species = row.get("species", "").strip()
            genus = row.get("genus", "").strip()

            if species and species.lower() not in ("", "nan", "none"):
                species_data.append({
                    "taxid": tax_id,
                    "species": species,
                    "abundance": abundance
                })

            if genus and genus.lower() not in ("", "nan", "none"):
                genus_data.append({
                    "taxid": tax_id,
                    "genus": genus,
                    "abundance": abundance
                })

    return species_data, genus_data

# Find all Emu abundance files
emu_files = list(emu_dir.glob("*/*_rel-abundance.tsv"))
if not emu_files:
    log("[postprocess] No Emu rel-abundance files found")
    # Still continue to copy any existing files

log(f"[postprocess] Found {len(emu_files)} Emu abundance file(s)")

all_species = []
all_genus = []

for emu_file in emu_files:
    barcode = emu_file.parent.name
    species_data, genus_data = parse_emu_abundance(emu_file)

    for row in species_data:
        all_species.append({
            "sample_id": barcode,
            "taxid": row["taxid"],
            "species": row["species"],
            "abundance": row["abundance"]
        })

    for row in genus_data:
        all_genus.append({
            "sample_id": barcode,
            "taxid": row["taxid"],
            "genus": row["genus"],
            "abundance": row["abundance"]
        })

def write_tidy_csv(path, rows, taxon_col):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["sample_id", "taxid", taxon_col, "abundance"])
        w.writeheader()
        for r in rows:
            w.writerow(r)

species_tidy = postprocess_dir / "emu_species_tidy.csv"
genus_tidy = postprocess_dir / "emu_genus_tidy.csv"

if all_species:
    write_tidy_csv(species_tidy, all_species, "species")
    log(f"[postprocess] Wrote species tidy CSV: {species_tidy}")

if all_genus:
    write_tidy_csv(genus_tidy, all_genus, "genus")
    log(f"[postprocess] Wrote genus tidy CSV: {genus_tidy}")

log("[postprocess] Emu tidy CSVs ready")

tables_dir = final_dir / "tables"
tables_dir.mkdir(exist_ok=True)

# Copy Emu abundance files to tables
if emu_dir.exists():
    for bc_dir in emu_dir.iterdir():
        if bc_dir.is_dir():
            for f in bc_dir.glob("*_rel-abundance*.tsv"):
                dest_name = f"{bc_dir.name}_{f.name}"
                shutil.copy2(f, tables_dir / dest_name)
                log(f"[postprocess] Copied Emu: {dest_name}")

# Copy tidy CSVs to tables
if species_tidy.exists():
    shutil.copy2(species_tidy, tables_dir / "emu_species_tidy.csv")
if genus_tidy.exists():
    shutil.copy2(genus_tidy, tables_dir / "emu_genus_tidy.csv")

# Copy VALENCIA outputs if available
valencia_final = final_dir / "valencia"
valencia_final.mkdir(exist_ok=True)

if valencia_dir and valencia_dir.exists() and any(valencia_dir.glob("*")):
    for f in valencia_dir.glob("*.csv"):
        shutil.copy2(f, valencia_final / f.name)
        log(f"[postprocess] Copied VALENCIA: {f.name}")
    for f in valencia_dir.glob("*.svg"):
        shutil.copy2(f, valencia_final / f.name)
        log(f"[postprocess] Copied VALENCIA plot: {f.name}")
    # Also check plots subdirectory
    plots_subdir = valencia_dir / "plots"
    if plots_subdir.exists():
        for f in plots_subdir.glob("*.svg"):
            shutil.copy2(f, valencia_final / f.name)
            log(f"[postprocess] Copied VALENCIA plot: {f.name}")

plots_dir = final_dir / "plots"
plots_dir.mkdir(exist_ok=True)

manifest = {
    "module": module_name,
    "run_name": run_name,
    "classifier": "emu",  # lr_amp is Emu-only
    "outputs": {
        "tables": sorted([f.name for f in tables_dir.glob("*")]) if tables_dir.exists() else [],
        "plots": sorted([f.name for f in plots_dir.iterdir() if f.suffix.lower() in ('.png', '.svg', '.pdf')]) if plots_dir.exists() else [],
        "valencia": sorted([f.name for f in valencia_final.glob("*")]) if valencia_final.exists() else []
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
  log_info "=== lr_amp Pipeline (Emu-only) ==="
  log_info "Technology: ${TECHNOLOGY}"
  log_info "Seq type (minimap2 preset): ${SEQ_TYPE}"
  log_info "Full-length: ${FULL_LENGTH}"
  log_info "Input style: ${INPUT_STYLE}"

  local started ended ec

  # If FAST5 input, run basecalling pipeline first
  if [[ "${INPUT_STYLE}" == "FAST5_DIR" || "${INPUT_STYLE}" == "FAST5" ]]; then
    log_info "FAST5 input detected - running basecalling pipeline..."

    # Step 1: Convert FAST5 to POD5
    started="$(iso_now)"
    set +e
    local pod5_file
    pod5_file="$(convert_fast5_to_pod5)"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 || -z "${pod5_file}" ]]; then
      steps_append "${STEPS_JSON}" "fast5_to_pod5" "failed" "FAST5 to POD5 conversion failed" "${POD5_BIN}" "pod5 convert" "${ec}" "${started}" "${ended}"
      die "FAST5 to POD5 conversion failed"
    fi
    steps_append "${STEPS_JSON}" "fast5_to_pod5" "succeeded" "FAST5 to POD5 conversion completed" "${POD5_BIN}" "pod5 convert" "${ec}" "${started}" "${ended}"
    log_ok "POD5 conversion complete: ${pod5_file}"

    # Step 2: Dorado basecalling
    started="$(iso_now)"
    set +e
    local bam_file
    bam_file="$(dorado_basecall_to_bam "${pod5_file}")"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 || -z "${bam_file}" ]]; then
      steps_append "${STEPS_JSON}" "dorado_basecall" "failed" "Dorado basecalling failed" "${DORADO_BIN}" "dorado basecaller" "${ec}" "${started}" "${ended}"
      die "Dorado basecalling failed"
    fi
    steps_append "${STEPS_JSON}" "dorado_basecall" "succeeded" "Dorado basecalling completed" "${DORADO_BIN}" "dorado basecaller" "${ec}" "${started}" "${ended}"
    log_ok "Basecalling complete: ${bam_file}"

    # Step 3: Dorado demux
    started="$(iso_now)"
    set +e
    local demux_dir
    demux_dir="$(dorado_demux_to_per_barcode_bam "${bam_file}")"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 || -z "${demux_dir}" ]]; then
      steps_append "${STEPS_JSON}" "dorado_demux" "failed" "Dorado demux failed" "${DORADO_BIN}" "dorado demux" "${ec}" "${started}" "${ended}"
      die "Dorado demux failed"
    fi
    steps_append "${STEPS_JSON}" "dorado_demux" "succeeded" "Dorado demux completed" "${DORADO_BIN}" "dorado demux" "${ec}" "${started}" "${ended}"
    log_ok "Demux complete: ${demux_dir}"

    # Step 4: Dorado trim + BAM to FASTQ
    started="$(iso_now)"
    set +e
    PER_BARCODE_FASTQ_ROOT="$(dorado_trim_bam_to_fastq_per_barcode "${demux_dir}")"
    ec=$?
    set -e
    ended="$(iso_now)"
    if [[ $ec -ne 0 || -z "${PER_BARCODE_FASTQ_ROOT}" ]]; then
      steps_append "${STEPS_JSON}" "dorado_trim_bam2fq" "failed" "Dorado trim + BAM to FASTQ failed" "${DORADO_BIN}" "dorado trim + samtools bam2fq" "${ec}" "${started}" "${ended}"
      die "Dorado trim + BAM to FASTQ failed"
    fi
    steps_append "${STEPS_JSON}" "dorado_trim_bam2fq" "succeeded" "Dorado trim + BAM to FASTQ completed" "${DORADO_BIN}" "dorado trim + samtools bam2fq" "${ec}" "${started}" "${ended}"
    log_ok "Trim + bam2fq complete: ${PER_BARCODE_FASTQ_ROOT}"

    # Discover barcode IDs from the generated FASTQs
    BARCODE_IDS=()
    shopt -s nullglob
    for bc_dir in "${PER_BARCODE_FASTQ_ROOT}"/*/; do
      [[ -d "${bc_dir}" ]] || continue
      local bc_name
      bc_name="$(basename "${bc_dir}")"
      BARCODE_IDS+=("${bc_name}")
    done
    shopt -u nullglob
    log_info "Discovered ${#BARCODE_IDS[@]} barcodes from basecalling"

    # Update outputs.json with basecalling results
    tmp="${OUTPUTS_JSON}.tmp"
    jq --arg per_barcode_root "${PER_BARCODE_FASTQ_ROOT}" \
       --arg pod5_file "${pod5_file}" \
       --arg bam_file "${bam_file}" \
       --arg demux_dir "${demux_dir}" \
       '. + {
          "basecalling": {
            "pod5_file": $pod5_file,
            "bam_file": $bam_file,
            "demux_dir": $demux_dir
          },
          "inputs": (.inputs + { "per_barcode_root": $per_barcode_root })
        }' "${OUTPUTS_JSON}" > "${tmp}"
    mv "${tmp}" "${OUTPUTS_JSON}"
  elif [[ "${INPUT_STYLE}" == "BAM" ]]; then
    log_info "BAM input detected - skipping basecalling, starting from demux/trim..."

    local bam_file="${STAGED_BAM}"

    # Step 1: Dorado demux (if barcode kit specified)
    if [[ -n "${BARCODE_KIT}" && "${BARCODE_KIT}" != "null" ]]; then
      started="$(iso_now)"
      set +e
      local demux_dir
      demux_dir="$(dorado_demux_to_per_barcode_bam "${bam_file}")"
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -ne 0 || -z "${demux_dir}" ]]; then
        steps_append "${STEPS_JSON}" "dorado_demux" "failed" "Dorado demux failed" "${DORADO_BIN}" "dorado demux" "${ec}" "${started}" "${ended}"
        die "Dorado demux failed"
      fi
      steps_append "${STEPS_JSON}" "dorado_demux" "succeeded" "Dorado demux completed" "${DORADO_BIN}" "dorado demux" "${ec}" "${started}" "${ended}"
      log_ok "Demux complete: ${demux_dir}"

      # Step 2: Dorado trim + BAM to FASTQ
      started="$(iso_now)"
      set +e
      PER_BARCODE_FASTQ_ROOT="$(dorado_trim_bam_to_fastq_per_barcode "${demux_dir}")"
      ec=$?
      set -e
      ended="$(iso_now)"
      if [[ $ec -ne 0 || -z "${PER_BARCODE_FASTQ_ROOT}" ]]; then
        steps_append "${STEPS_JSON}" "dorado_trim_bam2fq" "failed" "Dorado trim + BAM to FASTQ failed" "${DORADO_BIN}" "dorado trim + samtools bam2fq" "${ec}" "${started}" "${ended}"
        die "Dorado trim + BAM to FASTQ failed"
      fi
      steps_append "${STEPS_JSON}" "dorado_trim_bam2fq" "succeeded" "Dorado trim + BAM to FASTQ completed" "${DORADO_BIN}" "dorado trim + samtools bam2fq" "${ec}" "${started}" "${ended}"
      log_ok "Trim + bam2fq complete: ${PER_BARCODE_FASTQ_ROOT}"
    else
      # No barcode kit - treat as single sample, just trim
      log_info "No barcode kit specified - treating BAM as single sample"
      make_dir "${TRIM_DIR}"
      make_dir "${RAW_READS_DIR}/${RUN_NAME}"

      local trimmed_bam="${TRIM_DIR}/${RUN_NAME}_trimmed.bam"
      local cmd=( "${DORADO_BIN}" trim "${bam_file}" )
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
      if [[ $ec -ne 0 ]]; then
        steps_append "${STEPS_JSON}" "dorado_trim" "failed" "Dorado trim failed" "${DORADO_BIN}" "dorado trim" "${ec}" "${started}" "${ended}"
        die "Dorado trim failed"
      fi
      steps_append "${STEPS_JSON}" "dorado_trim" "succeeded" "Dorado trim completed" "${DORADO_BIN}" "dorado trim" "${ec}" "${started}" "${ended}"

      # Convert to FASTQ
      local fqdir="${RAW_READS_DIR}/${RUN_NAME}/sample"
      make_dir "${fqdir}"
      local fq="${fqdir}/sample.fastq"
      "${SAMTOOLS_BIN}" bam2fq "${trimmed_bam}" > "${fq}"

      PER_BARCODE_FASTQ_ROOT="${RAW_READS_DIR}/${RUN_NAME}"
      BARCODE_IDS=("sample")
      log_ok "Trim + bam2fq complete: ${PER_BARCODE_FASTQ_ROOT}"
    fi

    # Discover barcode IDs from the generated FASTQs
    if [[ -z "${BARCODE_IDS:-}" ]]; then
      BARCODE_IDS=()
      shopt -s nullglob
      for bc_dir in "${PER_BARCODE_FASTQ_ROOT}"/*/; do
        [[ -d "${bc_dir}" ]] || continue
        local bc_name
        bc_name="$(basename "${bc_dir}")"
        BARCODE_IDS+=("${bc_name}")
      done
      shopt -u nullglob
    fi
    log_info "Discovered ${#BARCODE_IDS[@]} sample(s) from BAM input"

    # Update outputs.json
    tmp="${OUTPUTS_JSON}.tmp"
    jq --arg per_barcode_root "${PER_BARCODE_FASTQ_ROOT}" \
       --arg bam_file "${bam_file}" \
       '. + {
          "bam_input": {
            "bam_file": $bam_file
          },
          "inputs": (.inputs + { "per_barcode_root": $per_barcode_root })
        }' "${OUTPUTS_JSON}" > "${tmp}"
    mv "${tmp}" "${OUTPUTS_JSON}"
  else
    log_info "Samples: ${#BARCODE_IDS[@]}"
  fi

  # Load barcode site map (must be after barcode IDs are discovered for FAST5 input)
  load_barcode_site_map "${SAMPLE_SHEET}"

  # Now continue with QC and taxonomy steps
  started="$(iso_now)"
  set +e
  qc_raw_per_barcode_fastq
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "raw_fastqc_multiqc" "succeeded" "raw fastqc + multiqc completed" "${FASTQC_BIN}" "fastqc + multiqc" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "raw_fastqc_multiqc" "skipped" "raw fastqc + multiqc skipped" "${FASTQC_BIN}" "fastqc + multiqc" "${ec}" "${started}" "${ended}"
  fi

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

  started="$(iso_now)"
  set +e
  length_filter_per_barcode
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "length_filter" "succeeded" "length filter completed or skipped" "${NANOFILT_BIN}" "NanoFilt length" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "length_filter" "failed" "length filter failed" "${NANOFILT_BIN}" "NanoFilt length" "${ec}" "${started}" "${ended}"
    exit $ec
  fi

  started="$(iso_now)"
  set +e
  emu_classification_per_barcode
  ec=$?
  set -e
  ended="$(iso_now)"
  if [[ $ec -eq 0 ]]; then
    steps_append "${STEPS_JSON}" "emu_primary" "succeeded" "Emu classification completed or skipped" "${EMU_BIN}" "emu abundance" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "emu_primary" "skipped" "Emu classification skipped" "${EMU_BIN}" "emu abundance" "${ec}" "${started}" "${ended}"
  fi

  # Kraken2 is disabled for lr_amp (Emu-only pipeline)
  started="$(iso_now)"
  kraken2_secondary_per_barcode  # This is now a no-op that logs "disabled"
  ended="$(iso_now)"
  steps_append "${STEPS_JSON}" "taxonomy_kraken2" "skipped" "Kraken2 disabled for lr_amp (Emu-only)" "" "" "0" "${started}" "${ended}"

  # Run VALENCIA (inline Python, mirrors sr_amp approach)
  run_valencia

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
    steps_append "${STEPS_JSON}" "postprocess" "succeeded" "postprocess completed" "python3" "python3 postprocess" "${ec}" "${started}" "${ended}"
  else
    steps_append "${STEPS_JSON}" "postprocess" "failed" "postprocess failed" "python3" "python3 postprocess" "${ec}" "${started}" "${ended}"
  fi

  # lr_amp is Emu-only - collect Emu outputs
  local emu_run_dir="${EMU_DIR}/${RUN_NAME}"
  local emu_files_json="[]"
  if [[ -d "${emu_run_dir}" ]]; then
    shopt -s nullglob
    local emu_abundance_files=( "${emu_run_dir}"/*/*_rel-abundance.tsv )
    shopt -u nullglob
    if [[ ${#emu_abundance_files[@]} -gt 0 ]]; then
      emu_files_json="$(printf '%s\n' "${emu_abundance_files[@]}" | jq -R . | jq -s .)"
    fi
  fi

  tmp="${OUTPUTS_JSON}.tmp"
  jq --arg steps_path "${STEPS_JSON}" \
     --arg results_dir "${RESULTS_DIR}" \
     --arg emu_dir "${emu_run_dir}" \
     --arg seq_type "${SEQ_TYPE}" \
     --arg valencia_dir "${VALENCIA_DIR:-}" \
     --arg postprocess_dir "${postprocess_dir}" \
     --arg postprocess_log "${postprocess_log}" \
     --arg final_dir "${final_dir}" \
     --argjson emu_files "${emu_files_json}" \
     '. + {
        "steps_path":$steps_path,
        "results_dir":$results_dir,
        "classifier": "emu",
        "seq_type": $seq_type,
        "emu": {
          "dir": $emu_dir,
          "abundance_files": $emu_files
        },
        "valencia_dir":$valencia_dir,
        "postprocess":{"dir":$postprocess_dir, "log":$postprocess_log},
        "final_dir":$final_dir
      }' "${OUTPUTS_JSON}" > "${tmp}"
  mv "${tmp}" "${OUTPUTS_JSON}"

  log_done "PIPELINE COMPLETE"
  log_done "Run: ${RUN_NAME}"
  log_done "Module out: ${MODULE_OUT_DIR}"
  log_done "Outputs: ${OUTPUTS_JSON}"
}

main "$@"

echo "[${MODULE_NAME}] Step staging complete (Emu-only pipeline)"
if [[ "${INPUT_STYLE}" == "FAST5_DIR" || "${INPUT_STYLE}" == "FAST5" ]]; then
  print_step_status "${STEPS_JSON}" "fast5_to_pod5"
  print_step_status "${STEPS_JSON}" "dorado_basecall"
  print_step_status "${STEPS_JSON}" "dorado_demux"
  print_step_status "${STEPS_JSON}" "dorado_trim_bam2fq"
fi
print_step_status "${STEPS_JSON}" "raw_fastqc_multiqc"
print_step_status "${STEPS_JSON}" "qfilter"
print_step_status "${STEPS_JSON}" "length_filter"
print_step_status "${STEPS_JSON}" "emu_primary"
print_step_status "${STEPS_JSON}" "taxonomy_kraken2"
print_step_status "${STEPS_JSON}" "valencia"
print_step_status "${STEPS_JSON}" "postprocess"
echo "[${MODULE_NAME}] seq_type: ${SEQ_TYPE}"
echo "[${MODULE_NAME}] outputs.json: ${OUTPUTS_JSON}"
echo "[${MODULE_NAME}] final outputs: ${MODULE_OUT_DIR}/final"
