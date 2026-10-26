#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stamina_biome_run.sh --config <path/to/config.json> [--force-overwrite] [--debug]

Runs the selected pipeline module (lr_meta, lr_amp, sr_meta, sr_amp) using the provided config.
Creates a run directory, writes effective_config.json, logs to runs/<run_id>/logs/<pipeline>.log,
and writes outputs.json.

For sr_meta and sr_amp pipelines, this script will automatically invoke run_in_container.sh
to run the pipeline inside the appropriate Docker container with correct mounts.

Options:
  --config <path>        Path to config.json (required)
  --force-overwrite      Overwrite existing run directory
  --debug                Enable xtrace (set -x)
  -h, --help             Show this help
EOF
}

# Check if we're running inside a container (set by run_in_container.sh)
is_in_container() {
  [[ "${STAMINA_BIOME_IN_CONTAINER:-}" == "1" ]]
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

now_iso() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

sanitize_id() {
  echo "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cd 'a-z0-9_-' \
    | sed 's/^-*//;s/-*$//'
}

parse_bool() {
  local v="${1:-}"
  v="$(printf "%s" "${v}" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')"
  case "${v}" in
    1|true|yes|y|on) return 0 ;;
    0|false|no|n|off|"") return 1 ;;
    *) return 1 ;;
  esac
}

require_field() {
  local jq_expr="$1"
  local friendly="$2"
  local val
  val="$(jq -r "${jq_expr} // empty" "${CONFIG_PATH}" | tr -d '\r\n' || true)"
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    echo "ERROR: Missing required field: ${friendly}" >&2
    echo "       (Looked for jq: ${jq_expr})" >&2
    exit 4
  fi
}

# Check if ANY of the provided jq expressions returns a value
require_field_any() {
  local friendly="$1"
  shift
  local val=""
  local tried_exprs=""
  for jq_expr in "$@"; do
    val="$(jq -r "${jq_expr} // empty" "${CONFIG_PATH}" | tr -d '\r\n' || true)"
    if [[ -n "${val}" && "${val}" != "null" ]]; then
      return 0
    fi
    tried_exprs="${tried_exprs} ${jq_expr}"
  done
  echo "ERROR: Missing required field: ${friendly}" >&2
  echo "       (Looked for jq:${tried_exprs})" >&2
  exit 4
}

jq_first_string() {
  local file="$1"; shift
  local v=""
  for expr in "$@"; do
    v="$(jq -r "${expr} // empty" "${file}" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "${v}" && "${v}" != "null" ]]; then
      echo "${v}"
      return 0
    fi
  done
  return 1
}

require_kraken_db_for_sr_meta() {
  local cfg="$1"

  # First check for new-style host.resources configuration (host path)
  local host_path
  host_path="$(jq -r '.host.resources.kraken2_db.host_path // empty' "${cfg}" | tr -d '\r\n')"

  if [[ -n "${host_path}" && "${host_path}" != "null" ]]; then
    # Using new-style host.resources - validation done by run_in_container.sh
    echo "[validate] Kraken2 DB via host.resources: ${host_path}"
    return 0
  fi

  # Fall back to legacy mounts configuration
  local mount_path
  mount_path="$(jq -r '.host.mounts.kraken2_db_classify // empty' "${cfg}" | tr -d '\r\n')"

  if [[ -n "${mount_path}" && "${mount_path}" != "null" ]]; then
    echo "[validate] Kraken2 DB via host.mounts: ${mount_path}"
    return 0
  fi

  # Legacy: check tools.kraken2.db
  local db
  db="$(jq_first_string "${cfg}" \
    '.tools.kraken2.db' \
    '.tools.kraken2.db_classify' \
    '.tools.kraken2_db' \
    '.kraken2.db' \
    '.kraken2.db_classify' \
    || true
  )"

  if [[ -z "${db}" ]]; then
    cat >&2 <<EOF
ERROR: No Kraken2 database specified for sr_meta.

Recommended: Use host.resources in your config:
  "host": {
    "resources": {
      "kraken2_db": {
        "host_path": "/path/to/kraken_db_dir",
        "container_path": "/refs/kraken2_db"
      }
    }
  }

Legacy (still supported):
  "tools": { "kraken2": { "db": "/path/to/kraken_db_dir" } }

If you run via pipelines/run_in_container.sh, you can instead pass:
  --kraken_database /path/to/kraken_db_dir

EOF
    exit 4
  fi

  # If the path starts with /db/ or /refs/, it's a container path - don't validate on host
  if [[ "${db}" == /db/* || "${db}" == /refs/* ]]; then
    echo "[validate] Kraken2 DB container path: ${db}"
    return 0
  fi

  # If we're in a container, container paths may already be mounted
  if is_in_container; then
    if [[ -d "${db}" ]]; then
      echo "[validate] Kraken2 DB path OK: ${db}"
    else
      echo "[validate] Kraken2 DB path: ${db} (will verify at runtime)"
    fi
    return 0
  fi

  # Outside container - validate host path
  if [[ ! -d "${db}" ]]; then
    cat >&2 <<EOF
ERROR: Kraken2 database path does not exist (or is not a directory):

  ${db}

For sr_meta you must provide a valid Kraken2 DB directory.

EOF
    exit 4
  fi
  echo "[validate] Kraken2 DB path OK: ${db}"
}

require_minimap2_human_ref_if_host_removal() {
  local cfg="$1"

  local remove_host
  remove_host="$(jq -r '.params.common.remove_host // 0' "${cfg}" | tr -d '\r\n')"

  # Check if host removal is enabled
  if [[ "${remove_host}" != "1" && "${remove_host}" != "true" ]]; then
    return 0  # Host removal not enabled, nothing to validate
  fi

  # First check for new-style host.resources configuration (host path)
  local host_path
  host_path="$(jq -r '.host.resources.minimap2_human_ref.host_path // empty' "${cfg}" | tr -d '\r\n')"

  if [[ -n "${host_path}" && "${host_path}" != "null" ]]; then
    echo "[validate] Minimap2 human ref via host.resources: ${host_path}"
    return 0
  fi

  # Legacy: check tools.minimap2.human_mmi
  local human_mmi
  human_mmi="$(jq_first_string "${cfg}" \
    '.tools.minimap2.human_mmi' \
    '.tools.human_mmi' \
    '.minimap2.human_mmi' \
    '.host_depletion.human_mmi' \
    || true
  )"

  if [[ -z "${human_mmi}" ]]; then
    cat >&2 <<EOF
WARNING: Host removal is enabled (params.common.remove_host=1) but no minimap2 human reference configured.

Recommended: Use host.resources in your config:
  "host": {
    "resources": {
      "minimap2_human_ref": {
        "host_path": "/path/to/human_reference_dir_or_file",
        "container_path": "/refs/human",
        "index_filename": "GRCh38.mmi"
      }
    }
  }

Legacy (still supported):
  "tools": {
    "minimap2": {
      "human_mmi": "/path/to/GRCh38.mmi"
    }
  }

EOF
    # Don't fail - allow pipeline to continue and fail at runtime
    return 0
  fi

  # If the path starts with /refs/, it's a container path
  if [[ "${human_mmi}" == /refs/* ]]; then
    echo "[validate] Minimap2 human ref container path: ${human_mmi}"
    return 0
  fi

  # If we're in a container, don't validate host paths
  if is_in_container; then
    echo "[validate] Minimap2 human ref: ${human_mmi}"
    return 0
  fi

  # Outside container - validate host path
  if [[ ! -e "${human_mmi}" ]]; then
    echo "WARNING: Minimap2 human reference not found: ${human_mmi}" >&2
    echo "         Host depletion may fail at runtime." >&2
  else
    echo "[validate] Minimap2 human ref path OK: ${human_mmi}"
  fi
}

# Post-run output validation - ensure expected outputs exist
validate_outputs() {
  local run_dir="$1"
  local pipeline_key="$2"
  local cfg="$3"
  local module_log="$4"

  local missing_outputs=()
  local found_outputs=()
  local module_dir="${run_dir}/${pipeline_key}"

  # Check for module outputs.json (written by module)
  local module_outputs="${module_dir}/outputs.json"
  if [[ ! -f "${module_outputs}" ]]; then
    echo "[output-check] WARNING: Module did not write outputs.json to ${module_outputs}"
  fi

  # Check for metrics.json
  local metrics="${module_dir}/metrics.json"
  if [[ ! -f "${metrics}" ]]; then
    echo "[output-check] WARNING: Module did not write metrics.json to ${metrics}"
  fi

  # Check for steps.json
  local steps="${module_dir}/steps.json"
  if [[ ! -f "${steps}" ]]; then
    echo "[output-check] WARNING: Module did not write steps.json to ${steps}"
  fi

  # Check expected outputs based on pipeline
  case "${pipeline_key}" in
    sr_meta)
      local results_dir="${module_dir}/results"

      if [[ -d "${results_dir}/fastqc" ]]; then
        found_outputs+=("fastqc")
      else
        missing_outputs+=("fastqc results directory")
      fi

      if [[ -d "${results_dir}/multiqc" ]]; then
        found_outputs+=("multiqc")
      else
        missing_outputs+=("multiqc results directory")
      fi

      if [[ -d "${results_dir}/kraken2" ]]; then
        found_outputs+=("kraken2")
      else
        missing_outputs+=("kraken2 results directory")
      fi
      ;;

    sr_amp)
      local results_dir="${module_dir}/results"

      if [[ -d "${results_dir}/fastqc" ]]; then
        found_outputs+=("fastqc")
      else
        missing_outputs+=("fastqc results directory")
      fi

      if [[ -d "${results_dir}/multiqc" ]]; then
        found_outputs+=("multiqc")
      else
        missing_outputs+=("multiqc results directory")
      fi

      if [[ -d "${results_dir}/qiime2" ]]; then
        found_outputs+=("qiime2")
      else
        missing_outputs+=("qiime2 results directory")
      fi
      ;;

    lr_meta)
      local module_results_dir="${module_dir}/results"
      local final_dir="${module_dir}/final"
      # Standardized results directory (at run_dir level, produced by R postprocess)
      local std_results_dir="${run_dir}/results"

      # lr_meta kraken2: check taxonomy dir for kreport files OR results/tables for copied kreports
      local has_kraken2="0"
      if [[ -d "${module_results_dir}/taxonomy" ]]; then
        # Check for .kreport files anywhere under taxonomy/
        shopt -s nullglob
        local kreport_files=( "${module_results_dir}/taxonomy"/*/*.kreport "${module_results_dir}/taxonomy"/*/*/*.kreport )
        shopt -u nullglob
        if [[ ${#kreport_files[@]} -gt 0 ]]; then
          has_kraken2="1"
        fi
      fi
      # Check standardized results/tables (where R postprocess copies kreports)
      if [[ -d "${std_results_dir}/tables" ]]; then
        shopt -s nullglob
        local std_kreport_files=( "${std_results_dir}/tables"/*.kreport "${std_results_dir}/tables"/*kraken*.csv )
        shopt -u nullglob
        if [[ ${#std_kreport_files[@]} -gt 0 ]]; then
          has_kraken2="1"
        fi
      fi
      # Also check legacy final/tables
      if [[ -d "${final_dir}/tables" ]]; then
        shopt -s nullglob
        local final_kreport_files=( "${final_dir}/tables"/*.kreport )
        shopt -u nullglob
        if [[ ${#final_kreport_files[@]} -gt 0 ]]; then
          has_kraken2="1"
        fi
      fi

      if [[ "${has_kraken2}" == "1" ]]; then
        found_outputs+=("kraken2")
      else
        missing_outputs+=("kraken2 results")
      fi

      # lr_meta valencia: check standardized results/valencia OR module valencia results dir
      local has_valencia="0"
      if [[ -d "${std_results_dir}/valencia" ]]; then
        shopt -s nullglob
        local std_valencia_files=( "${std_results_dir}/valencia"/*valencia*.csv "${std_results_dir}/valencia"/*.csv )
        shopt -u nullglob
        if [[ ${#std_valencia_files[@]} -gt 0 ]]; then
          has_valencia="1"
        fi
      fi
      if [[ -d "${module_results_dir}/valencia/results" ]]; then
        shopt -s nullglob
        local valencia_files=( "${module_results_dir}/valencia/results"/*_valencia*.csv "${module_results_dir}/valencia/results"/*.png )
        shopt -u nullglob
        if [[ ${#valencia_files[@]} -gt 0 ]]; then
          has_valencia="1"
        fi
      fi
      if [[ "${has_valencia}" == "1" ]]; then
        found_outputs+=("valencia")
      fi

      # lr_meta plots: check standardized results/plots OR legacy final/plots
      local has_plots="0"
      if [[ -d "${std_results_dir}/plots" ]]; then
        shopt -s nullglob
        local std_plot_files=( "${std_results_dir}/plots"/*.png "${std_results_dir}/plots"/*.pdf )
        shopt -u nullglob
        if [[ ${#std_plot_files[@]} -gt 0 ]]; then
          has_plots="1"
        fi
      fi
      if [[ -d "${final_dir}/plots" ]]; then
        shopt -s nullglob
        local plot_files=( "${final_dir}/plots"/*.png )
        shopt -u nullglob
        if [[ ${#plot_files[@]} -gt 0 ]]; then
          has_plots="1"
        fi
      fi
      if [[ "${has_plots}" == "1" ]]; then
        found_outputs+=("plots")
      fi

      # Check for manifest in standardized location OR legacy
      if [[ -f "${std_results_dir}/manifest.json" ]]; then
        found_outputs+=("manifest")
      elif [[ -f "${final_dir}/manifest.json" ]]; then
        found_outputs+=("manifest")
      fi
      ;;
  esac

  if [[ ${#found_outputs[@]} -gt 0 ]]; then
    echo "[output-check] Found outputs: ${found_outputs[*]}"
  fi

  if [[ ${#missing_outputs[@]} -gt 0 ]]; then
    echo ""
    echo "================================================================================"
    echo "WARNING: Some expected outputs were not created"
    echo "================================================================================"
    for m in "${missing_outputs[@]}"; do
      echo "  - Missing: ${m}"
    done
    echo ""
    echo "Check the module log for errors: ${module_log}"
    echo "================================================================================"
    return 1
  fi

  return 0
}

CONFIG_PATH=""
FORCE_OVERWRITE_CLI="0"
DEBUG="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --force-overwrite) FORCE_OVERWRITE_CLI="1"; shift 1 ;;
    --debug) DEBUG="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${CONFIG_PATH}" ]]; then
  echo "ERROR: --config is required" >&2
  usage
  exit 1
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  die "Config file not found: ${CONFIG_PATH}"
fi

if ! command -v jq >/dev/null 2>&1; then
  die "jq is required but not found in PATH"
fi

if ! jq -e . "${CONFIG_PATH}" >/dev/null 2>&1; then
  die "Config is not valid JSON: ${CONFIG_PATH}"
fi

if [[ "${DEBUG}" == "1" ]]; then
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"

PIPELINE_ID_RAW="$(jq -r '
  .pipeline_id
  // .pipelineId
  // .pipeline.id
  // .pipeline.pipeline_id
  // empty
' "${CONFIG_PATH}" | tr -d '\r\n')"

if [[ -z "${PIPELINE_ID_RAW}" || "${PIPELINE_ID_RAW}" == "null" ]]; then
  echo "ERROR: Could not find pipeline_id in config. Expected one of:" >&2
  echo "  .pipeline_id | .pipelineId | .pipeline.id | .pipeline.pipeline_id" >&2
  exit 4
fi

PIPELINE_KEY="$(sanitize_id "${PIPELINE_ID_RAW}")"
PIPELINE_KEY="${PIPELINE_KEY//-/_}"

# -----------------------------------------------------------------------------
# CRITICAL: Pipelines MUST run inside a container with proper mounts.
# If we're not already in a container, delegate to run_in_container.sh
# -----------------------------------------------------------------------------
requires_container() {
  case "$1" in
    sr_meta|sr_amp|lr_meta|lr_amp) return 0 ;;
    *) return 1 ;;
  esac
}

echo "[dispatch] Pipeline: ${PIPELINE_KEY}"
echo "[dispatch] STAMINA_BIOME_IN_CONTAINER=${STAMINA_BIOME_IN_CONTAINER:-<not set>}"

if requires_container "${PIPELINE_KEY}"; then
  if is_in_container; then
    echo "[dispatch] Running INSIDE container - proceeding with module execution"
  else
    echo "[dispatch] Running OUTSIDE container - delegating to run_in_container.sh"
    echo ""

    DELEGATE_ARGS=( --config "${CONFIG_PATH}" )
    [[ "${FORCE_OVERWRITE_CLI}" == "1" ]] && DELEGATE_ARGS+=( --force-overwrite )
    [[ "${DEBUG}" == "1" ]] && DELEGATE_ARGS+=( --debug )

    RUN_CONTAINER_SCRIPT="${SCRIPT_DIR}/run_in_container.sh"
    if [[ ! -f "${RUN_CONTAINER_SCRIPT}" ]]; then
      die "CRITICAL: run_in_container.sh not found at: ${RUN_CONTAINER_SCRIPT}"
    fi
    if [[ ! -x "${RUN_CONTAINER_SCRIPT}" ]]; then
      chmod +x "${RUN_CONTAINER_SCRIPT}" || die "Cannot make run_in_container.sh executable"
    fi

    echo "[dispatch] Executing: ${RUN_CONTAINER_SCRIPT} ${DELEGATE_ARGS[*]}"
    exec "${RUN_CONTAINER_SCRIPT}" "${DELEGATE_ARGS[@]}"
  fi
else
  echo "[dispatch] Pipeline '${PIPELINE_KEY}' does not require container - running on host"
fi

RUN_ID="$(jq -r '.run.run_id // .run_id // .runId // .run.id // empty' "${CONFIG_PATH}" | tr -d '\r\n')"

WORK_DIR_RAW="$(jq -r '
  .run.work_dir
  // .work_dir
  // .workDir
  // .run.output_dir
  // .output_dir
  // .outputDir
  // empty
' "${CONFIG_PATH}" | tr -d '\r\n')"

if [[ -z "${WORK_DIR_RAW}" || "${WORK_DIR_RAW}" == "null" ]]; then
  if is_in_container; then
    WORK_DIR_RAW="/work/runs"
  else
    WORK_DIR_RAW="${REPO_ROOT}/runs"
  fi
fi

FORCE_OVERWRITE_CFG="$(jq -r '
  .run.force_overwrite
  // .force_overwrite
  // .forceOverwrite
  // empty
' "${CONFIG_PATH}" | tr -d '\r\n')"

FORCE_OVERWRITE="0"
if parse_bool "${FORCE_OVERWRITE_CFG}"; then
  FORCE_OVERWRITE="1"
fi
if [[ "${FORCE_OVERWRITE_CLI}" == "1" ]]; then
  FORCE_OVERWRITE="1"
fi

INPUT_STYLE_RAW="$(jq -r '.input.style // .inputStyle // empty' "${CONFIG_PATH}" | tr -d '\r\n')"
INPUT_STYLE_CANON="$(echo "${INPUT_STYLE_RAW}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_-' )"
INPUT_STYLE_CANON="${INPUT_STYLE_CANON//-/_}"

# Validate input style based on pipeline type
# Long-read pipelines (lr_*) only support single-end FASTQ - no R1/R2 pairs
IS_LONG_READ_PIPELINE="0"
if [[ "${PIPELINE_KEY}" == lr_* ]]; then
  IS_LONG_READ_PIPELINE="1"
fi

case "${INPUT_STYLE_CANON}" in
  FAST5_DIR) require_field ".input.fast5_dir" "input.fast5_dir (path to directory of FAST5 files)" ;;
  FAST5_ARCHIVE) require_field ".input.fast5_archive" "input.fast5_archive (path to .zip or .tar.gz)" ;;
  FASTQ_SINGLE)
    # For long-read: only accept .input.fastq (no R1/R2 concept)
    # For short-read: accept either .input.fastq or .input.fastq_r1
    if [[ "${IS_LONG_READ_PIPELINE}" == "1" ]]; then
      require_field ".input.fastq" "input.fastq (path to FASTQ for long-read single-end)"
      echo "[validate] Long-read pipeline: using single-end FASTQ mode (no R1/R2)" >&2
    else
      require_field_any "input.fastq or input.fastq_r1 (path to FASTQ for single-end)" ".input.fastq" ".input.fastq_r1"
    fi
    ;;
  FASTQ_PAIRED)
    # Long-read pipelines do NOT support paired-end
    if [[ "${IS_LONG_READ_PIPELINE}" == "1" ]]; then
      echo "ERROR: Long-read pipeline '${PIPELINE_KEY}' does not support FASTQ_PAIRED input style." >&2
      echo "       Long-read sequencing produces single-end reads only." >&2
      echo "       Use input.style = 'FASTQ_SINGLE' with input.fastq = '<path>'" >&2
      exit 4
    fi
    require_field ".input.fastq_r1" "input.fastq_r1 (path to FASTQ R1)"
    require_field ".input.fastq_r2" "input.fastq_r2 (path to FASTQ R2)"
    ;;
  FASTQ_DIR_SINGLE) require_field ".input.fastq_dir" "input.fastq_dir (directory containing single-end FASTQs)" ;;
  FASTQ_DIR_PAIRED)
    # Long-read pipelines do NOT support paired-end
    if [[ "${IS_LONG_READ_PIPELINE}" == "1" ]]; then
      echo "ERROR: Long-read pipeline '${PIPELINE_KEY}' does not support FASTQ_DIR_PAIRED input style." >&2
      echo "       Long-read sequencing produces single-end reads only." >&2
      echo "       Use input.style = 'FASTQ_DIR_SINGLE' with input.fastq_dir = '<path>'" >&2
      exit 4
    fi
    require_field ".input.fastq_dir" "input.fastq_dir (directory containing paired-end FASTQs)"
    ;;
  "") echo "WARNING: No input.style provided. Continuing." >&2 ;;
  *) echo "WARNING: Unrecognized input.style '${INPUT_STYLE_RAW}' (canon: '${INPUT_STYLE_CANON}'). Continuing." >&2 ;;
esac

RUN_ID_RESOLVED="$(sanitize_id "${RUN_ID}")"
if [[ -z "${RUN_ID_RESOLVED}" ]]; then
  RUN_ID_RESOLVED="${PIPELINE_KEY}_$(date +%Y%m%d_%H%M%S)"
fi

WORK_DIR="${WORK_DIR_RAW%/}"
RUN_DIR="${WORK_DIR}/${RUN_ID_RESOLVED}"

echo "[dispatch] work_dir: ${WORK_DIR}"
echo "[dispatch] run_dir: ${RUN_DIR}"

if [[ -d "${RUN_DIR}" ]]; then
  if [[ "${FORCE_OVERWRITE}" == "1" ]]; then
    rm -rf "${RUN_DIR}"
  else
    echo "ERROR: Run directory already exists: ${RUN_DIR}" >&2
    echo "       Use --force-overwrite or set run.force_overwrite=1 to overwrite it." >&2
    exit 6
  fi
fi

mkdir -p "${RUN_DIR}/logs" "${RUN_DIR}/artifacts"
cp -f "${CONFIG_PATH}" "${RUN_DIR}/config.original.json"

EFFECTIVE_CONFIG_PATH="${RUN_DIR}/effective_config.json"

JQ_EFF_ARGS=(
  --arg run_dir "${RUN_DIR}"
  --arg run_id "${RUN_ID_RESOLVED}"
  --arg pipeline_key "${PIPELINE_KEY}"
  --arg repo_root_container "${REPO_ROOT}"
)

jq "${JQ_EFF_ARGS[@]}" '
  . + {
    "run_dir": $run_dir,
    "run_id_resolved": $run_id,
    "pipeline_key": $pipeline_key
  }
  | .run = (
      (.run // {}) + {
        "run_dir": $run_dir,
        "run_id_resolved": $run_id,
        "repo_root_container": $repo_root_container
      }
    )
' "${CONFIG_PATH}" > "${EFFECTIVE_CONFIG_PATH}"

# Early friendly requirement: sr_meta must have a Kraken2 DB
if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  require_kraken_db_for_sr_meta "${EFFECTIVE_CONFIG_PATH}"
fi

# Validate minimap2 human reference if host removal is enabled (sr_meta, lr_meta)
if [[ "${PIPELINE_KEY}" == "sr_meta" || "${PIPELINE_KEY}" == "lr_meta" ]]; then
  require_minimap2_human_ref_if_host_removal "${EFFECTIVE_CONFIG_PATH}"
fi

MODULE_SCRIPT=""
case "${PIPELINE_KEY}" in
  lr_meta) MODULE_SCRIPT="${MODULES_DIR}/lr_meta.sh" ;;
  lr_amp)  MODULE_SCRIPT="${MODULES_DIR}/lr_amp.sh" ;;
  sr_meta) MODULE_SCRIPT="${MODULES_DIR}/sr_meta.sh" ;;
  sr_amp)  MODULE_SCRIPT="${MODULES_DIR}/sr_amp.sh" ;;
  *)
    echo "ERROR: No module mapping for pipeline_id '${PIPELINE_ID_RAW}' (normalized: '${PIPELINE_KEY}')" >&2
    exit 5
    ;;
esac

if [[ ! -f "${MODULE_SCRIPT}" ]]; then
  die "Module script not found: ${MODULE_SCRIPT}"
fi

chmod +x "${MODULE_SCRIPT}" || true

MODULE_LOG="${RUN_DIR}/logs/${PIPELINE_KEY}.log"

{
  echo "[dispatch] pipeline_id: ${PIPELINE_ID_RAW}"
  echo "[dispatch] pipeline_key: ${PIPELINE_KEY}"
  echo "[dispatch] input_style: ${INPUT_STYLE_RAW}"
  echo "[dispatch] run_dir: ${RUN_DIR}"
  echo "[dispatch] module: ${MODULE_SCRIPT}"
  echo "[dispatch] effective_config: ${EFFECTIVE_CONFIG_PATH}"
  echo "[dispatch] started_at: $(now_iso)"
  echo
} | tee -a "${MODULE_LOG}" >/dev/null

set +e
# Invoke module with explicit bash interpreter to bypass non-portable shebangs
# (e.g. sr_meta.sh has /opt/homebrew/bin/bash which doesn't exist in container)
bash "${MODULE_SCRIPT}" --config "${EFFECTIVE_CONFIG_PATH}" 2>&1 | tee -a "${MODULE_LOG}"
MODULE_EXIT="${PIPESTATUS[0]}"
set -e

{
  echo
  echo "[dispatch] ended_at: $(now_iso)"
  echo "[dispatch] exit_code: ${MODULE_EXIT}"
} | tee -a "${MODULE_LOG}" >/dev/null

OUTPUTS_JSON="${RUN_DIR}/outputs.json"

JQ_OUT_ARGS=(
  -n
  --arg pipeline_id "${PIPELINE_ID_RAW}"
  --arg pipeline_key "${PIPELINE_KEY}"
  --arg run_id "${RUN_ID_RESOLVED}"
  --arg run_dir "${RUN_DIR}"
  --arg module_log "${MODULE_LOG}"
  --argjson success "$( [[ "${MODULE_EXIT}" == "0" ]] && echo true || echo false )"
  --argjson exit_code "${MODULE_EXIT}"
)

jq "${JQ_OUT_ARGS[@]}" '
  {
    pipeline_id: $pipeline_id,
    pipeline_key: $pipeline_key,
    run_id: $run_id,
    run_dir: $run_dir,
    success: $success,
    exit_code: $exit_code,
    logs: { module: $module_log },
    artifacts: {}
  }
' > "${OUTPUTS_JSON}"

if [[ "${MODULE_EXIT}" != "0" ]]; then
  echo "ERROR: Module failed with exit code ${MODULE_EXIT}" >&2
  echo "       See log: ${MODULE_LOG}" >&2
  exit "${MODULE_EXIT}"
fi

# -----------------------------------------------------------------------------
# R Postprocessing (optional, config-controlled)
# Runs on HOST after container module completes successfully
# -----------------------------------------------------------------------------
run_r_postprocess() {
  local cfg="$1"
  local run_dir="$2"
  local pipeline_key="$3"
  local module_log="$4"

  # Check if postprocess is enabled in config
  local enabled
  enabled="$(jq -r '.postprocess.enabled // 0' "${cfg}" 2>/dev/null || echo "0")"
  if [[ "${enabled}" != "1" ]]; then
    echo "[r_postprocess] Postprocess disabled (postprocess.enabled != 1)"
    return 0
  fi

  # Find the module outputs.json
  local module_outputs="${run_dir}/${pipeline_key}/outputs.json"
  if [[ ! -f "${module_outputs}" ]]; then
    echo "[r_postprocess] Module outputs.json not found: ${module_outputs}"
    return 0
  fi

  # Find the R postprocess runner
  local r_runner="${SCRIPT_DIR}/postprocess/r/run_r_postprocess.sh"
  if [[ ! -f "${r_runner}" ]]; then
    echo "[r_postprocess] R postprocess runner not found: ${r_runner}"
    return 0
  fi

  echo ""
  echo "[r_postprocess] Running R postprocessing on host..."
  echo "[r_postprocess] Config: ${cfg}"
  echo "[r_postprocess] Outputs: ${module_outputs}"
  echo "[r_postprocess] Module: ${pipeline_key}"

  set +e
  bash "${r_runner}" --config "${cfg}" --outputs "${module_outputs}" --module "${pipeline_key}" 2>&1 | tee -a "${module_log}"
  local r_ec="${PIPESTATUS[0]}"
  set -e

  if [[ "${r_ec}" -ne 0 ]]; then
    echo "[r_postprocess] R postprocessing reported errors (exit code ${r_ec}), but pipeline continues"
  else
    echo "[r_postprocess] R postprocessing completed successfully"
  fi

  return 0
}

# Run R postprocessing for pipelines that support it (HOST only - R not available in container)
if [[ "${PIPELINE_KEY}" == "sr_meta" || "${PIPELINE_KEY}" == "sr_amp" || "${PIPELINE_KEY}" == "lr_meta" || "${PIPELINE_KEY}" == "lr_amp" ]]; then
  if ! is_in_container; then
    run_r_postprocess "${EFFECTIVE_CONFIG_PATH}" "${RUN_DIR}" "${PIPELINE_KEY}" "${MODULE_LOG}"
  else
    echo "[r_postprocess] Skipping R postprocess inside container (will run on host after container exits)"
  fi
fi

# Validate expected outputs exist
OUTPUT_CHECK_FAILED="0"
if ! validate_outputs "${RUN_DIR}" "${PIPELINE_KEY}" "${EFFECTIVE_CONFIG_PATH}" "${MODULE_LOG}"; then
  OUTPUT_CHECK_FAILED="1"
fi

echo "[done] Success. outputs.json: ${OUTPUTS_JSON}"

# Show final summary
echo ""
echo "================================================================================"
echo "Pipeline completed: ${PIPELINE_KEY}"
echo "================================================================================"
echo "Run directory: ${RUN_DIR}"
echo "Module log: ${MODULE_LOG}"
echo "Config used: ${EFFECTIVE_CONFIG_PATH}"
if [[ "${OUTPUT_CHECK_FAILED}" == "1" ]]; then
  echo ""
  echo "NOTE: Some expected outputs may be missing. Check the log above."
fi
echo "================================================================================"
