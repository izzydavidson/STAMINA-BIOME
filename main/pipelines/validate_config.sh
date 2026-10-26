#!/usr/bin/env bash
# =============================================================================
# validate_config.sh - Validate STAMINA-BIOME pipeline configuration
#
# This script validates a config file before running the pipeline, checking:
#   1. JSON syntax
#   2. Required fields for the specified pipeline
#   3. Host resource paths exist (Kraken2 DB, Minimap2 human reference)
#   4. Docker Desktop file sharing compatibility (macOS)
#
# Usage:
#   pipelines/validate_config.sh --config <path/to/config.json> [--check-mounts]
#
# Options:
#   --config <path>    Path to config.json (required)
#   --check-mounts     Verify paths are Docker-shareable (macOS)
#   --quiet            Only output errors, no success messages
#   -h, --help         Show this help
# =============================================================================
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate_config.sh --config <path/to/config.json> [--check-mounts] [--quiet]

Validates a STAMINA-BIOME config file, checking:
  1. JSON syntax is valid
  2. Required fields exist for the specified pipeline
  3. Host resource paths (Kraken2 DB, Minimap2 reference) exist if specified
  4. Paths are Docker-shareable on macOS (with --check-mounts)

Options:
  --config <path>    Path to config.json (required)
  --check-mounts     Verify paths are Docker-shareable (macOS)
  --quiet            Only output errors, no success messages
  -h, --help         Show this help

Exit codes:
  0 - Config is valid
  1 - Config syntax error
  2 - Missing required field
  3 - Resource path does not exist
  4 - Path not Docker-shareable (macOS, with --check-mounts)
EOF
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() { echo -e "${RED}ERROR:${NC} $*" >&2; }
warn() { echo -e "${YELLOW}WARNING:${NC} $*" >&2; }
success() { [[ "${QUIET}" == "0" ]] && echo -e "${GREEN}OK:${NC} $*"; }
info() { [[ "${QUIET}" == "0" ]] && echo "$*"; }

CONFIG_PATH=""
CHECK_MOUNTS="0"
QUIET="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --check-mounts) CHECK_MOUNTS="1"; shift 1 ;;
    --quiet|-q) QUIET="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${CONFIG_PATH}" ]]; then
  error "--config is required"
  usage
  exit 1
fi

if [[ ! -f "${CONFIG_PATH}" ]]; then
  error "Config file not found: ${CONFIG_PATH}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  error "jq is required but not found in PATH"
  exit 1
fi

# =============================================================================
# 1. Validate JSON syntax
# =============================================================================
info "Validating JSON syntax..."
if ! jq -e . "${CONFIG_PATH}" >/dev/null 2>&1; then
  error "Config is not valid JSON: ${CONFIG_PATH}"
  jq . "${CONFIG_PATH}" 2>&1 | head -5 >&2  # Show parse error
  exit 1
fi
success "JSON syntax is valid"

# =============================================================================
# Helper to extract value with fallbacks
# =============================================================================
jq_first() {
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

# =============================================================================
# 2. Check pipeline_id and extract pipeline type
# =============================================================================
info "Checking pipeline_id..."
PIPELINE_ID="$(jq_first "${CONFIG_PATH}" \
  '.pipeline_id' \
  '.pipelineId' \
  '.pipeline.id' \
  '.pipeline.pipeline_id' \
  || true
)"

if [[ -z "${PIPELINE_ID}" ]]; then
  error "Missing required field: pipeline_id"
  echo "Expected one of: .pipeline_id | .pipelineId | .pipeline.id | .pipeline.pipeline_id" >&2
  exit 2
fi

# Normalize pipeline key
PIPELINE_KEY="$(echo "${PIPELINE_ID}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
PIPELINE_KEY="${PIPELINE_KEY//-/_}"

case "${PIPELINE_KEY}" in
  sr_amp|sr_meta|lr_amp|lr_meta)
    success "pipeline_id: ${PIPELINE_ID} (${PIPELINE_KEY})"
    ;;
  *)
    error "Invalid pipeline_id: ${PIPELINE_ID}"
    echo "Supported: sr_amp, sr_meta, lr_amp, lr_meta" >&2
    exit 2
    ;;
esac

# =============================================================================
# 3. Check required fields based on pipeline
# =============================================================================
info "Checking required fields..."

# Check input.style
INPUT_STYLE="$(jq_first "${CONFIG_PATH}" '.input.style' '.inputs.style' || true)"
if [[ -z "${INPUT_STYLE}" ]]; then
  warn "Missing input.style - will use default based on pipeline"
fi
success "input.style: ${INPUT_STYLE:-<default>}"

# Check resources.threads
THREADS="$(jq_first "${CONFIG_PATH}" '.resources.threads' || true)"
if [[ -z "${THREADS}" ]]; then
  warn "Missing resources.threads - will default to 1"
fi
success "resources.threads: ${THREADS:-1}"

# =============================================================================
# 4. Validate host.resources paths
# =============================================================================
info "Checking host.resources..."

# Kraken2 DB
KRAKEN2_HOST_PATH="$(jq -r '.host.resources.kraken2_db.host_path // empty' "${CONFIG_PATH}" | tr -d '\r\n')"
KRAKEN2_CONTAINER_PATH="$(jq -r '.host.resources.kraken2_db.container_path // empty' "${CONFIG_PATH}" | tr -d '\r\n')"

if [[ -n "${KRAKEN2_HOST_PATH}" ]]; then
  if [[ -d "${KRAKEN2_HOST_PATH}" ]]; then
    success "host.resources.kraken2_db.host_path exists: ${KRAKEN2_HOST_PATH}"
    success "  -> container_path: ${KRAKEN2_CONTAINER_PATH:-/refs/kraken2_db}"
  else
    error "Kraken2 DB path does not exist: ${KRAKEN2_HOST_PATH}"
    exit 3
  fi
else
  # Check legacy paths
  KRAKEN2_LEGACY="$(jq_first "${CONFIG_PATH}" \
    '.host.mounts.kraken2_db_classify' \
    '.tools.kraken2.db' \
    '.kraken2.db' \
    || true
  )"
  if [[ -n "${KRAKEN2_LEGACY}" ]]; then
    info "Using legacy Kraken2 config: ${KRAKEN2_LEGACY}"
  elif [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
    warn "No Kraken2 DB configured - required for sr_meta pipeline"
  fi
fi

# Minimap2 human reference
MINIMAP2_HOST_PATH="$(jq -r '.host.resources.minimap2_human_ref.host_path // empty' "${CONFIG_PATH}" | tr -d '\r\n')"
MINIMAP2_CONTAINER_PATH="$(jq -r '.host.resources.minimap2_human_ref.container_path // empty' "${CONFIG_PATH}" | tr -d '\r\n')"
MINIMAP2_INDEX_FILENAME="$(jq -r '.host.resources.minimap2_human_ref.index_filename // empty' "${CONFIG_PATH}" | tr -d '\r\n')"

if [[ -n "${MINIMAP2_HOST_PATH}" ]]; then
  if [[ -e "${MINIMAP2_HOST_PATH}" ]]; then
    success "host.resources.minimap2_human_ref.host_path exists: ${MINIMAP2_HOST_PATH}"
    success "  -> container_path: ${MINIMAP2_CONTAINER_PATH:-/refs/human}"
    if [[ -n "${MINIMAP2_INDEX_FILENAME}" ]]; then
      success "  -> index_filename: ${MINIMAP2_INDEX_FILENAME}"
    fi
  else
    error "Minimap2 human reference path does not exist: ${MINIMAP2_HOST_PATH}"
    exit 3
  fi
else
  # Check legacy path
  MINIMAP2_LEGACY="$(jq_first "${CONFIG_PATH}" \
    '.tools.minimap2.human_mmi' \
    '.minimap2.human_mmi' \
    || true
  )"
  REMOVE_HOST="$(jq -r '.params.common.remove_host // 0' "${CONFIG_PATH}" | tr -d '\r\n')"
  if [[ -n "${MINIMAP2_LEGACY}" ]]; then
    info "Using legacy minimap2 config: ${MINIMAP2_LEGACY}"
  elif [[ "${REMOVE_HOST}" == "1" || "${REMOVE_HOST}" == "true" ]]; then
    warn "Host removal enabled but no minimap2 human reference configured"
  fi
fi

# =============================================================================
# 5. Check Docker-shareable paths (macOS only)
# =============================================================================
if [[ "${CHECK_MOUNTS}" == "1" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  info "Checking Docker Desktop file sharing compatibility (macOS)..."

  check_shareable() {
    local path="$1"
    local name="$2"

    if [[ -z "${path}" ]]; then
      return 0
    fi

    local shareable=0
    for prefix in "/Users" "/Volumes" "/private" "/tmp" "/var/folders"; do
      if [[ "${path}" == "${prefix}"* ]]; then
        shareable=1
        break
      fi
    done

    if [[ "${shareable}" -eq 1 ]]; then
      success "${name} is Docker-shareable: ${path}"
    else
      error "${name} may NOT be Docker-shareable: ${path}"
      echo "  Docker Desktop typically only shares: /Users, /Volumes, /private, /tmp, /var/folders" >&2
      echo "  Add the path in Docker Desktop -> Settings -> Resources -> File Sharing" >&2
      return 4
    fi
    return 0
  }

  SHARE_ERRORS=0
  check_shareable "${KRAKEN2_HOST_PATH}" "Kraken2 DB" || SHARE_ERRORS=1
  check_shareable "${MINIMAP2_HOST_PATH}" "Minimap2 reference" || SHARE_ERRORS=1

  if [[ "${SHARE_ERRORS}" -eq 1 ]]; then
    exit 4
  fi
fi

# =============================================================================
# 6. Summary
# =============================================================================
echo ""
echo "==========================================="
if [[ "${QUIET}" == "0" ]]; then
  echo -e "${GREEN}Config validation PASSED${NC}"
else
  echo "Config validation PASSED"
fi
echo "  Pipeline: ${PIPELINE_KEY}"
echo "  Config: ${CONFIG_PATH}"
echo "==========================================="
exit 0
