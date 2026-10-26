#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pipelines/run_in_container.sh --config <path/to/config.json> [--rebuild] [--platform <os/arch>] [--kraken_database <path>]

What it does:
  - Reads pipeline_id from the config
  - Picks Dockerfile + image name based on pipeline_id
      lr_meta/lr_amp -> pipelines/container/dockerfile.lr -> stamina-biome-tools-lr:dev
      sr_meta/sr_amp -> pipelines/container/dockerfile.sr -> stamina-biome-tools-sr:dev
  - Builds the image if missing (or if --rebuild)
  - Runs pipelines/stamina_biome_run.sh --config <config> inside that container

sr_amp behavior:
  - Uses simple container setup: repo mounted at /work, working directory /work
  - Relative paths in config work directly (resolved relative to /work)
  - Uses built-in FastQC/MultiQC from the container (no QC wrappers)
  - Full pipeline: QC -> QIIME2 -> VALENCIA with all exports

sr_meta behavior:
  - Requires external resource mounts (Kraken2 DB, minimap2 human ref)
  - Supports low-memory host depletion mode (--lowmem-host-depletion)
  - Automatically selects best prebuilt .mmi index (lowmem > split2G > split4G > full)
  - QC wrappers available if QC image exists

Options:
  --config <path>          Required
  --rebuild                Force docker build even if image exists
  --platform <os/arch>     Optional. On ARM Mac: defaults to linux/arm64 for native execution.
  --kraken_database <path> Optional override for Kraken2 DB directory (sr_meta only)
  --no-host-removal        Disable host removal (minimap2 depletion) regardless of config setting
  --lowmem-host-depletion  Force low-memory mode for host depletion
  --minimap2-threads <N>   Override minimap2 thread count for host depletion (sr_meta only)
  --minimap2-K <SIZE>      Override minimap2 batch size (-K) for host depletion (e.g., 50M, 100M)
  --preflight-only         Validate config, mounts, and show chosen .mmi strategy without running
  --dry-run                Validate config and show docker command without running
  --force-overwrite        Overwrite existing run directory if it exists
  --debug                  Enable bash xtrace (set -x) for debugging
  -h, --help               Show this help
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# -----------------------------
# Docker daemon health check
# -----------------------------
check_docker_daemon() {
  echo "[preflight] Checking Docker daemon..."

  if ! command -v docker >/dev/null 2>&1; then
    die "docker command not found on PATH"
  fi

  local docker_info_output
  local docker_info_exit=0
  docker_info_output="$(docker info 2>&1)" || docker_info_exit=$?

  if [[ "${docker_info_exit}" -ne 0 ]]; then
    cat >&2 <<EOF
================================================================================
ERROR: Docker daemon is not available
================================================================================

Cannot connect to Docker daemon. This could mean:
  1. Docker Desktop is not running
  2. Docker daemon crashed
  3. Permission issues with Docker socket

Docker output:
${docker_info_output}

To fix:
  1. Start Docker Desktop (on macOS/Windows)
  2. Or start the Docker daemon: sudo systemctl start docker (on Linux)
  3. Verify with: docker info

================================================================================
EOF
    exit 125
  fi

  echo "[preflight] Docker daemon is running"
}

# -----------------------------
# Docker crash diagnostics (sr_meta specific)
# Differentiates: DAEMON_CRASH vs CONTAINER_OOM vs MODULE_ERROR
# -----------------------------
capture_docker_diagnostics() {
  local run_dir="$1"
  local container_name="$2"
  local exit_code="$3"
  local diag_file="${run_dir}/logs/docker_diagnostics.txt"

  mkdir -p "$(dirname "${diag_file}")" 2>/dev/null || true

  # Determine failure type
  local failure_type="UNKNOWN"
  local daemon_alive="0"
  local oom_killed="false"
  local container_exit_code=""

  # Check if daemon is alive
  if docker info >/dev/null 2>&1; then
    daemon_alive="1"
  fi

  # Check container state if daemon is alive
  if [[ "${daemon_alive}" == "1" ]]; then
    if docker inspect "${container_name}" >/dev/null 2>&1; then
      oom_killed="$(docker inspect "${container_name}" 2>/dev/null | jq -r '.[0].State.OOMKilled // false' 2>/dev/null || echo "false")"
      container_exit_code="$(docker inspect "${container_name}" 2>/dev/null | jq -r '.[0].State.ExitCode // ""' 2>/dev/null || echo "")"
    fi
  fi

  # Classify failure
  if [[ "${daemon_alive}" == "0" ]]; then
    failure_type="DAEMON_CRASH"
  elif [[ "${oom_killed}" == "true" ]]; then
    failure_type="CONTAINER_OOM"
  elif [[ "${exit_code}" == "125" ]]; then
    failure_type="DAEMON_ERROR"
  elif [[ "${exit_code}" == "137" ]]; then
    failure_type="CONTAINER_KILLED"
  elif [[ "${exit_code}" -ge 1 && "${exit_code}" -le 127 ]]; then
    failure_type="MODULE_ERROR"
  fi

  {
    echo "================================================================================"
    echo "Docker Diagnostics Report"
    echo "================================================================================"
    echo "Generated:     $(date -Iseconds 2>/dev/null || date)"
    echo "Container:     ${container_name}"
    echo "Exit Code:     ${exit_code}"
    echo "Failure Type:  ${failure_type}"
    echo "Daemon Alive:  ${daemon_alive}"
    echo "OOM Killed:    ${oom_killed}"
    echo "================================================================================"
    echo ""

    case "${failure_type}" in
      DAEMON_CRASH)
        echo "*** DIAGNOSIS: Docker daemon crashed or became unresponsive ***"
        echo ""
        echo "The Docker daemon is not responding. This typically happens when:"
        echo "  1. Docker Desktop ran out of memory and crashed"
        echo "  2. Docker Desktop was manually stopped/restarted"
        echo "  3. System went to sleep or hibernated"
        echo ""
        echo "Recommended actions:"
        echo "  1. Restart Docker Desktop"
        echo "  2. Increase Docker Desktop memory allocation"
        echo "  3. Use --lowmem-host-depletion flag"
        echo "  4. Use a smaller .mmi index (lowmem.mmi)"
        ;;
      CONTAINER_OOM)
        echo "*** DIAGNOSIS: Container killed by OOM (Out of Memory) ***"
        echo ""
        echo "The container exceeded its memory limit and was killed."
        echo ""
        echo "Recommended actions:"
        echo "  1. Use --lowmem-host-depletion flag"
        echo "  2. Use --minimap2-threads 1 --minimap2-K 50M"
        echo "  3. Increase Docker Desktop memory to 12GB+"
        echo "  4. Use a smaller .mmi index (lowmem.mmi)"
        ;;
      MODULE_ERROR)
        echo "*** DIAGNOSIS: Pipeline module error (not a Docker issue) ***"
        echo ""
        echo "The pipeline module exited with an error code. Check the module logs"
        echo "for details about what failed."
        ;;
    esac
    echo ""

    echo "--- docker info ---"
    docker info 2>&1 || echo "(docker info failed - daemon may be down)"
    echo ""

    echo "--- docker ps -a (last 10) ---"
    docker ps -a --last 10 2>&1 || echo "(docker ps failed)"
    echo ""

    echo "--- Container Inspect ---"
    if [[ "${daemon_alive}" == "1" ]] && docker inspect "${container_name}" >/dev/null 2>&1; then
      local inspect_json
      inspect_json="$(docker inspect "${container_name}" 2>&1)"
      echo "${inspect_json}"
      echo ""

      echo "--- Container State Summary ---"
      echo "OOMKilled: $(echo "${inspect_json}" | jq -r '.[0].State.OOMKilled // "unknown"' 2>/dev/null || echo "unknown")"
      echo "ExitCode: $(echo "${inspect_json}" | jq -r '.[0].State.ExitCode // "unknown"' 2>/dev/null || echo "unknown")"
      echo "Error: $(echo "${inspect_json}" | jq -r '.[0].State.Error // "none"' 2>/dev/null || echo "none")"
      echo "Status: $(echo "${inspect_json}" | jq -r '.[0].State.Status // "unknown"' 2>/dev/null || echo "unknown")"
    else
      echo "(Container not found or cannot be inspected - daemon may be down)"
    fi
    echo ""

    echo "--- Container Logs (last 50 lines) ---"
    docker logs --tail 50 "${container_name}" 2>&1 || echo "(Could not retrieve logs)"
    echo ""

    echo "--- Docker System df ---"
    docker system df 2>&1 || echo "(docker system df failed)"
    echo ""

    echo "--- End of Diagnostics ---"
  } > "${diag_file}" 2>&1

  echo "[diagnostics] Failure type: ${failure_type}"
  echo "[diagnostics] Saved to: ${diag_file}"
}

# -----------------------------
# Host path validation helpers
# -----------------------------
validate_host_path_exists() {
  local path="$1"
  local resource_name="$2"
  local is_directory="${3:-auto}"  # auto, directory, file

  if [[ -z "${path}" || "${path}" == "null" ]]; then
    return 0  # Empty path is OK (optional resource)
  fi

  if [[ ! -e "${path}" ]]; then
    cat >&2 <<EOF
ERROR: ${resource_name} host path does not exist:
  ${path}

Please verify:
  1. The path is correct and accessible
  2. The external drive/volume is mounted (if applicable)
EOF

    # macOS-specific hints
    if [[ "$(uname -s)" == "Darwin" ]]; then
      cat >&2 <<EOF

macOS Docker Desktop Note:
  Ensure the path is shared with Docker Desktop:
    Docker Desktop -> Settings -> Resources -> File Sharing

  Common shareable paths: /Users, /Volumes, /private, /tmp
  If path is on an external drive, ensure /Volumes is shared.
EOF
    fi
    return 1
  fi

  case "${is_directory}" in
    directory)
      if [[ ! -d "${path}" ]]; then
        echo "ERROR: ${resource_name} path exists but is not a directory: ${path}" >&2
        return 1
      fi
      ;;
    file)
      if [[ ! -f "${path}" ]]; then
        echo "ERROR: ${resource_name} path exists but is not a file: ${path}" >&2
        return 1
      fi
      ;;
  esac

  return 0
}

check_external_volume_sharing() {
  local path="$1"
  local resource_name="$2"

  if [[ -z "${path}" || "${path}" == "null" ]]; then
    return 0
  fi

  # Only check on macOS
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi

  # Check if path is on an external volume (/Volumes/...)
  if [[ "${path}" == /Volumes/* ]]; then
    local volume_name
    volume_name="$(echo "${path}" | cut -d'/' -f3)"
    local volume_path="/Volumes/${volume_name}"

    # First check if the volume is actually mounted
    if [[ ! -d "${volume_path}" ]]; then
      cat >&2 <<EOF
================================================================================
ERROR: External volume not mounted: ${volume_path}
================================================================================

${resource_name} is configured on an external drive that is not currently mounted:
  ${path}

Please:
  1. Connect the external drive
  2. Ensure it mounts at: ${volume_path}
  3. Re-run the pipeline

================================================================================
EOF
      return 1
    fi

    # Try a quick Docker mount test to see if the path is shareable
    echo "[preflight] Checking Docker Desktop can access external volume: ${volume_path}..."

    local test_result
    if ! test_result="$(docker run --rm -v "${volume_path}:/test_mount:ro" alpine:latest ls /test_mount 2>&1)"; then
      cat >&2 <<EOF
================================================================================
ERROR: Docker Desktop cannot access external volume: ${volume_path}
================================================================================

${resource_name} is on an external drive that Docker Desktop cannot mount:
  ${path}

This usually means /Volumes is not shared with Docker Desktop.

To fix this (macOS Docker Desktop):
  1. Open Docker Desktop
  2. Go to Settings (gear icon) -> Resources -> File Sharing
  3. Click '+' and add: /Volumes
  4. Click 'Apply & Restart'
  5. Re-run the pipeline

Technical details:
  ${test_result}
================================================================================
EOF
      return 1
    fi
    echo "[preflight] External volume accessible: ${volume_path}"
  fi

  return 0
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

CONFIG_PATH=""
REBUILD="0"
PLATFORM_OVERRIDE=""
KRAKEN_DB_CLASSIFY_CLI=""
FORCE_NO_HOST_REMOVAL="0"
FORCE_LOWMEM_HOST_DEPLETION="0"
DRY_RUN="0"
FORCE_OVERWRITE="0"
DEBUG_MODE="0"
PREFLIGHT_ONLY="0"

# sr_meta-specific CLI overrides for minimap2 memory controls
CLI_MINIMAP2_THREADS=""
CLI_MINIMAP2_K=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG_PATH="${2:-}"; shift 2 ;;
    --rebuild) REBUILD="1"; shift 1 ;;
    --platform) PLATFORM_OVERRIDE="${2:-}"; shift 2 ;;
    --kraken_database|--kraken-db) KRAKEN_DB_CLASSIFY_CLI="${2:-}"; shift 2 ;;
    --no-host-removal) FORCE_NO_HOST_REMOVAL="1"; shift 1 ;;
    --lowmem-host-depletion) FORCE_LOWMEM_HOST_DEPLETION="1"; shift 1 ;;
    --minimap2-threads) CLI_MINIMAP2_THREADS="${2:-}"; shift 2 ;;
    --minimap2-K|--minimap2-k) CLI_MINIMAP2_K="${2:-}"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY="1"; shift 1 ;;
    --dry-run) DRY_RUN="1"; shift 1 ;;
    --force-overwrite) FORCE_OVERWRITE="1"; shift 1 ;;
    --debug) DEBUG_MODE="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "${CONFIG_PATH}" ]] || { echo "ERROR: --config is required" >&2; usage; exit 1; }
[[ -f "${CONFIG_PATH}" ]] || die "Config file not found: ${CONFIG_PATH}"
command -v docker >/dev/null 2>&1 || die "docker is required but not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"

# Enable debug mode if requested
if [[ "${DEBUG_MODE}" == "1" ]]; then
  set -x
fi

# Check environment variable for lowmem mode
if [[ "${STAMINA_BIOME_LOWMEM_HOST_DEPLETION:-0}" == "1" ]]; then
  FORCE_LOWMEM_HOST_DEPLETION="1"
fi

# Check Docker daemon health BEFORE doing anything else
check_docker_daemon

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_DIR="${REPO_ROOT}/pipelines/container"
DISPATCHER_IN_CONTAINER="pipelines/stamina_biome_run.sh"

CONFIG_ABS="$(cd "$(dirname "${CONFIG_PATH}")" && pwd)/$(basename "${CONFIG_PATH}")"

jq -e . "${CONFIG_ABS}" >/dev/null 2>&1 || die "Config is not valid JSON: ${CONFIG_ABS}"

PIPELINE_ID_RAW="$(jq -r '
  .pipeline_id
  // .pipelineId
  // .pipeline.id
  // .pipeline.pipeline_id
  // empty
' "${CONFIG_ABS}" | tr -d '\r\n')"

[[ -n "${PIPELINE_ID_RAW}" && "${PIPELINE_ID_RAW}" != "null" ]] || {
  echo "ERROR: Could not find pipeline_id in config. Expected one of:" >&2
  echo "  .pipeline_id | .pipelineId | .pipeline.id | .pipeline.pipeline_id" >&2
  exit 4
}

PIPELINE_KEY="$(echo "${PIPELINE_ID_RAW}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-' )"
PIPELINE_KEY="${PIPELINE_KEY//-/_}"

DOCKERFILE_LR="${CONTAINER_DIR}/dockerfile.lr"
DOCKERFILE_SR="${CONTAINER_DIR}/dockerfile.sr"

IMAGE_NAME=""
DOCKERFILE_PATH=""
NEEDS_DOCKER_SOCK="0"

case "${PIPELINE_KEY}" in
  lr_meta|lr_amp)
    DOCKERFILE_PATH="${DOCKERFILE_LR}"
    IMAGE_NAME="stamina-biome-tools-lr:dev"
    NEEDS_DOCKER_SOCK="0"
    ;;
  sr_meta|sr_amp)
    DOCKERFILE_PATH="${DOCKERFILE_SR}"
    IMAGE_NAME="stamina-biome-tools-sr:dev"
    # sr_meta needs docker.sock for nested docker calls (QIIME2, QC wrappers)
    # sr_amp may need it for QIIME2 but NOT for QC (uses built-in tools)
    NEEDS_DOCKER_SOCK="1"
    ;;
  *)
    echo "ERROR: Unknown/unsupported pipeline_id '${PIPELINE_ID_RAW}' (normalized: '${PIPELINE_KEY}')" >&2
    echo "Supported: lr_meta, lr_amp, sr_meta, sr_amp" >&2
    exit 4
    ;;
esac

[[ -f "${DOCKERFILE_PATH}" ]] || die "Dockerfile not found at: ${DOCKERFILE_PATH}"

HOST_OS="$(uname -s || true)"
HOST_ARCH="$(uname -m || true)"

# -----------------------------
# Platform selection: use ARM64 on ARM hosts by default
# -----------------------------
PLATFORM=""
IS_ARM_HOST="0"

if [[ "${HOST_ARCH}" == "arm64" || "${HOST_ARCH}" == "aarch64" ]]; then
  IS_ARM_HOST="1"
fi

if [[ -n "${PLATFORM_OVERRIDE}" ]]; then
  PLATFORM="${PLATFORM_OVERRIDE}"
elif [[ "${IS_ARM_HOST}" == "1" ]]; then
  PLATFORM="linux/arm64"
fi

# Read host removal setting from config
HOST_REMOVAL_FROM_CONFIG="$(jq -r '
  .params.common.remove_host
  // .params.remove_host
  // .common.remove_host
  // .remove_host
  // 0
' "${CONFIG_ABS}" 2>/dev/null | tr -d '\r\n' || echo "0")"

# Normalize to 0 or 1
case "${HOST_REMOVAL_FROM_CONFIG}" in
  1|true|yes|on) HOST_REMOVAL_ENABLED="1" ;;
  *) HOST_REMOVAL_ENABLED="0" ;;
esac

# Determine if we need to disable host removal (only via explicit flag)
DISABLE_HOST_REMOVAL="0"
DISABLE_HOST_REMOVAL_REASON=""

if [[ "${FORCE_NO_HOST_REMOVAL}" == "1" ]]; then
  DISABLE_HOST_REMOVAL="1"
  DISABLE_HOST_REMOVAL_REASON="--no-host-removal flag specified"
fi

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

# -----------------------------
# sr_meta: Resource configuration from host.resources
# -----------------------------
KRAKEN2_DB_HOST_PATH=""
KRAKEN2_DB_CONTAINER_PATH="/refs/kraken2_db"
MINIMAP2_HUMAN_REF_HOST_PATH=""
MINIMAP2_HUMAN_REF_CONTAINER_PATH="/refs/human_genome"
MINIMAP2_HUMAN_REF_INDEX_FILENAME=""
SR_META_LOWMEM_MODE="0"

if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  # Read host.resources configuration
  KRAKEN2_DB_HOST_PATH="$(jq -r '.host.resources.kraken2_db.host_path // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  KRAKEN2_DB_CONTAINER_PATH_CFG="$(jq -r '.host.resources.kraken2_db.container_path // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  [[ -n "${KRAKEN2_DB_CONTAINER_PATH_CFG}" ]] && KRAKEN2_DB_CONTAINER_PATH="${KRAKEN2_DB_CONTAINER_PATH_CFG}"

  MINIMAP2_HUMAN_REF_HOST_PATH="$(jq -r '.host.resources.minimap2_human_ref.host_path // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  MINIMAP2_HUMAN_REF_CONTAINER_PATH_CFG="$(jq -r '.host.resources.minimap2_human_ref.container_path // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  [[ -n "${MINIMAP2_HUMAN_REF_CONTAINER_PATH_CFG}" ]] && MINIMAP2_HUMAN_REF_CONTAINER_PATH="${MINIMAP2_HUMAN_REF_CONTAINER_PATH_CFG}"
  MINIMAP2_HUMAN_REF_INDEX_FILENAME="$(jq -r '.host.resources.minimap2_human_ref.index_filename // empty' "${CONFIG_ABS}" | tr -d '\r\n')"

  # Fallback: try legacy host.mounts.kraken2_db_classify
  if [[ -z "${KRAKEN2_DB_HOST_PATH}" ]]; then
    KRAKEN2_DB_HOST_PATH="$(jq -r '.host.mounts.kraken2_db_classify // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  fi

  # CLI override for Kraken2 DB
  if [[ -n "${KRAKEN_DB_CLASSIFY_CLI}" ]]; then
    [[ -d "${KRAKEN_DB_CLASSIFY_CLI}" ]] || die "Kraken2 DB directory not found: ${KRAKEN_DB_CLASSIFY_CLI}"
    KRAKEN2_DB_HOST_PATH="${KRAKEN_DB_CLASSIFY_CLI}"
  fi

  # Validate required resources
  if [[ -z "${KRAKEN2_DB_HOST_PATH}" ]]; then
    cat >&2 <<EOF
ERROR: No Kraken2 database specified for sr_meta.

Provide it one of these ways:
  1) CLI:
       pipelines/run_in_container.sh --config ${CONFIG_PATH} --kraken_database /path/to/kraken_db_dir

  2) Config (recommended):
       "host": {
         "resources": {
           "kraken2_db": {
             "host_path": "/path/to/kraken_db_dir",
             "container_path": "/refs/kraken2_db"
           }
         }
       }

EOF
    exit 4
  fi

  # Validate Kraken2 DB path
  echo "[sr_meta] Validating resources..."
  if ! validate_host_path_exists "${KRAKEN2_DB_HOST_PATH}" "Kraken2 database" "directory"; then
    exit 4
  fi
  if ! check_external_volume_sharing "${KRAKEN2_DB_HOST_PATH}" "Kraken2 database"; then
    exit 4
  fi
  echo "[sr_meta] Kraken2 DB: ${KRAKEN2_DB_HOST_PATH} -> ${KRAKEN2_DB_CONTAINER_PATH}"

  # Validate minimap2 human reference if host removal is enabled
  if [[ "${HOST_REMOVAL_ENABLED}" == "1" && "${DISABLE_HOST_REMOVAL}" != "1" ]]; then
    if [[ -z "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      cat >&2 <<EOF
WARNING: Host depletion is enabled (params.common.remove_host=1) but no minimap2 human reference configured.

Configure it via host.resources:
  "host": {
    "resources": {
      "minimap2_human_ref": {
        "host_path": "/path/to/human_reference.fa",
        "container_path": "/refs/human_genome",
        "index_filename": "GRCh38.primary_assembly.genome.fa"
      }
    }
  }

The pipeline will continue but host depletion step may fail.
EOF
    else
      if ! validate_host_path_exists "${MINIMAP2_HUMAN_REF_HOST_PATH}" "Minimap2 human reference" "auto"; then
        exit 4
      fi
      if ! check_external_volume_sharing "${MINIMAP2_HUMAN_REF_HOST_PATH}" "Minimap2 human reference"; then
        exit 4
      fi
      echo "[sr_meta] Human ref: ${MINIMAP2_HUMAN_REF_HOST_PATH} -> ${MINIMAP2_HUMAN_REF_CONTAINER_PATH}"
    fi
  fi

  # -----------------------------
  # sr_meta: Low-memory mode detection
  # -----------------------------
  DOCKER_TOTAL_MEM_GB="$(docker system info 2>/dev/null | grep 'Total Memory' | sed 's/.*: *//' | sed 's/GiB//' | tr -d ' ' || echo "0")"
  DOCKER_TOTAL_MEM_GB="${DOCKER_TOTAL_MEM_GB%%.*}"
  [[ -z "${DOCKER_TOTAL_MEM_GB}" ]] && DOCKER_TOTAL_MEM_GB="0"

  LOW_MEM_THRESHOLD=9  # Enable lowmem if Docker has < 9GB

  if [[ "${FORCE_LOWMEM_HOST_DEPLETION}" == "1" ]]; then
    SR_META_LOWMEM_MODE="1"
    echo ""
    echo "================================================================================"
    echo "[sr_meta] LOW MEMORY MODE: Forced via CLI flag or environment variable"
    echo "================================================================================"
  elif [[ "${DOCKER_TOTAL_MEM_GB}" -gt 0 && "${DOCKER_TOTAL_MEM_GB}" -lt "${LOW_MEM_THRESHOLD}" ]]; then
    SR_META_LOWMEM_MODE="1"
    echo ""
    echo "================================================================================"
    echo "[sr_meta] LOW MEMORY MODE: Auto-enabled (Docker memory: ${DOCKER_TOTAL_MEM_GB}GB < ${LOW_MEM_THRESHOLD}GB)"
    echo "================================================================================"
  fi

  if [[ "${SR_META_LOWMEM_MODE}" == "1" ]]; then
    echo "[sr_meta] Low-memory optimizations enabled:"
    echo "  - kraken2 will use memory-mapping mode (--memory-mapping)"
    echo "  - Thread count reduced to 4"
    echo "  - Container resource limits applied"
    echo ""
    echo "NOTE: minimap2 split-index mode (-I) is NOT enabled because it produces"
    echo "      malformed SAM output when combined with on-the-fly index building."
    echo "      For large-scale host depletion, pre-build a minimap2 .mmi index."
    echo "================================================================================"
    echo ""
  fi
fi

# -----------------------------
# Build pipeline image (after validations)
# -----------------------------
if [[ "${REBUILD}" == "1" ]] || ! image_exists "${IMAGE_NAME}"; then
  echo "[container] Using Dockerfile: ${DOCKERFILE_PATH}"
  echo "[container] Building image: ${IMAGE_NAME}"
  BUILD_ARGS=(build)
  [[ -n "${PLATFORM}" ]] && BUILD_ARGS+=( --platform "${PLATFORM}" )
  [[ "${REBUILD}" == "1" ]] && BUILD_ARGS+=( --no-cache )
  BUILD_ARGS+=( --load -t "${IMAGE_NAME}" -f "${DOCKERFILE_PATH}" "${REPO_ROOT}" )

  echo "[container] Running: docker ${BUILD_ARGS[*]}"
  if ! docker "${BUILD_ARGS[@]}"; then
    cat >&2 <<EOF
================================================================================
ERROR: Docker build failed
================================================================================

The Docker image build failed. Common causes:
  1. Network issues downloading base images
  2. Docker daemon out of disk space
  3. Docker daemon crashed during build

Try:
  1. Run: docker system prune -f (to free space)
  2. Restart Docker Desktop
  3. Check Docker Desktop for error messages
  4. Re-run with --debug for more details

================================================================================
EOF
    exit 125
  fi
else
  echo "[container] Image exists: ${IMAGE_NAME} (use --rebuild to force rebuild)"
fi

# -----------------------------
# QC image selection + wrappers
# sr_amp: Uses built-in FastQC/MultiQC - NO wrappers
# sr_meta: Can use QC wrappers if available
# -----------------------------
QC_IMAGE_FROM_CONFIG="$(jq -r '
  .tools.qc_image
  // .tools.qc.image
  // .host.images.qc
  // .host.images.qc_image
  // empty
' "${CONFIG_ABS}" | tr -d '\r\n')"
QC_IMAGE_NAME="${QC_IMAGE_FROM_CONFIG:-${STAMINA_BIOME_QC_IMAGE:-stamina-biome-tools-qc:dev}}"

USE_QC_WRAPPERS="0"
WRAPPER_DIR=""
FASTQC_WRAPPER_IN_CONTAINER=""
MULTIQC_WRAPPER_IN_CONTAINER=""

# Only consider QC wrappers for sr_meta
if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  QC_DOCKERFILE_PATH=""
  for cand in \
    "${CONTAINER_DIR}/dockerfile.qc" \
    "${CONTAINER_DIR}/Dockerfile.qc" \
    "${CONTAINER_DIR}/docker.qc" \
  ; do
    if [[ -f "${cand}" ]]; then QC_DOCKERFILE_PATH="${cand}"; break; fi
  done

  if [[ -n "${QC_DOCKERFILE_PATH}" ]]; then
    if [[ "${REBUILD}" == "1" ]] || ! image_exists "${QC_IMAGE_NAME}"; then
      echo "[qc] Building QC image: ${QC_IMAGE_NAME}"
      QC_BUILD_ARGS=(build)
      [[ -n "${PLATFORM}" ]] && QC_BUILD_ARGS+=( --platform "${PLATFORM}" )
      [[ "${REBUILD}" == "1" ]] && QC_BUILD_ARGS+=( --no-cache )
      QC_BUILD_ARGS+=( --load -t "${QC_IMAGE_NAME}" -f "${QC_DOCKERFILE_PATH}" "${REPO_ROOT}" )
      docker "${QC_BUILD_ARGS[@]}" || echo "WARNING: QC image build failed, continuing without QC wrappers" >&2
    fi
  fi

  QC_AVAILABLE="0"
  if image_exists "${QC_IMAGE_NAME}"; then QC_AVAILABLE="1"; fi

  PIPELINE_HAS_DOCKER_CLI="0"
  if docker run --rm ${PLATFORM:+--platform "${PLATFORM}"} "${IMAGE_NAME}" sh -lc 'command -v docker >/dev/null 2>&1' >/dev/null 2>&1; then
    PIPELINE_HAS_DOCKER_CLI="1"
  fi

  if [[ "${QC_AVAILABLE}" == "1" && "${PIPELINE_HAS_DOCKER_CLI}" == "1" ]]; then
    USE_QC_WRAPPERS="1"
    echo "[qc] sr_meta: Using QC wrappers via image: ${QC_IMAGE_NAME}"
  fi

  if [[ "${USE_QC_WRAPPERS}" == "1" ]]; then
    NEEDS_DOCKER_SOCK="1"
  fi
elif [[ "${PIPELINE_KEY}" == "sr_amp" ]]; then
  # sr_amp uses built-in QC tools - explicitly no wrappers
  echo "[qc] sr_amp: Using built-in FastQC/MultiQC from container image"
fi

TMP_DIR="${REPO_ROOT}/.stamina-biome/tmp"
mkdir -p "${TMP_DIR}"
TMP_CONFIG="$(mktemp "${TMP_DIR}/config.XXXXXX")"

MINIMAP2_SHIM_DIR=""

cleanup() {
  if [[ "${DRY_RUN}" != "1" && "${PREFLIGHT_ONLY}" != "1" ]]; then
    rm -f "${TMP_CONFIG}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${WRAPPER_DIR}" && -d "${WRAPPER_DIR}" ]]; then
    rm -rf "${WRAPPER_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${MINIMAP2_SHIM_DIR}" && -d "${MINIMAP2_SHIM_DIR}" ]]; then
    rm -rf "${MINIMAP2_SHIM_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${USE_QC_WRAPPERS}" == "1" ]]; then
  WRAPPER_DIR="$(mktemp -d "${TMP_DIR}/wrappers.XXXXXX")"
  chmod 755 "${WRAPPER_DIR}"

  cat > "${WRAPPER_DIR}/fastqc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not found inside pipeline container" >&2; exit 127; }

QC_IMAGE="${STAMINA_BIOME_QC_IMAGE:-stamina-biome-tools-qc:dev}"
PLATFORM="${STAMINA_BIOME_DOCKER_PLATFORM:-}"
HOST_ROOT="${STAMINA_BIOME_HOST_REPO_ROOT:-}"
CONT_ROOT="${STAMINA_BIOME_CONTAINER_REPO_ROOT:-/work}"
HOST_UID="${STAMINA_BIOME_HOST_UID:-}"
HOST_GID="${STAMINA_BIOME_HOST_GID:-}"
HOST_OS="${STAMINA_BIOME_HOST_OS:-Linux}"
HOST_HOME="${STAMINA_BIOME_HOST_HOME:-}"

rewrite_path() {
  local p="$1"
  if [[ "${p}" != /* ]]; then
    p="${CONT_ROOT}/${p}"
  fi
  if [[ -n "${HOST_ROOT}" ]]; then
    if [[ "${p}" == "${CONT_ROOT}" ]]; then echo "${HOST_ROOT}"; return; fi
    if [[ "${p}" == "${CONT_ROOT}/"* ]]; then echo "${HOST_ROOT}${p#${CONT_ROOT}}"; return; fi
  fi
  echo "${p}"
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--outdir)
      flag="$1"; shift
      out="${1:-}"; [[ -n "${out}" ]] || { echo "ERROR: ${flag} requires a value" >&2; exit 2; }
      out_host="$(rewrite_path "${out}")"
      mkdir -p "${out_host}"
      args+=( "${flag}" "${out_host}" )
      shift
      ;;
    *)
      args+=( "$(rewrite_path "$1")" )
      shift
      ;;
  esac
done

docker_args=(run --rm)
[[ -n "${PLATFORM}" ]] && docker_args+=( --platform "${PLATFORM}" )
[[ -n "${HOST_UID}" && -n "${HOST_GID}" ]] && docker_args+=( --user "${HOST_UID}:${HOST_GID}" )

if [[ -n "${HOST_ROOT}" && -d "${HOST_ROOT}" ]]; then
  docker_args+=( -v "${HOST_ROOT}:${HOST_ROOT}:rw" )
fi
[[ -d "/Users" ]] && docker_args+=( -v "/Users:/Users:rw" )
[[ -d "/Volumes" ]] && docker_args+=( -v "/Volumes:/Volumes:rw" )

if [[ "${HOST_OS}" == "Darwin" ]]; then
  [[ -n "${HOST_HOME}" && -d "${HOST_HOME}" ]] && docker_args+=( -v "${HOST_HOME}:/home:rw" )
else
  [[ -d "/home" ]] && docker_args+=( -v "/home:/home:rw" )
fi

if [[ "${HOST_OS}" == "Linux" ]]; then
  [[ -d "/data" ]] && docker_args+=( -v "/data:/data:rw" )
  [[ -d "/mnt" ]] && docker_args+=( -v "/mnt:/mnt:rw" )
fi

docker_args+=( "${QC_IMAGE}" fastqc "${args[@]}" )
exec docker "${docker_args[@]}"
SH
  chmod 755 "${WRAPPER_DIR}/fastqc"

  cat > "${WRAPPER_DIR}/multiqc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not found inside pipeline container" >&2; exit 127; }

QC_IMAGE="${STAMINA_BIOME_QC_IMAGE:-stamina-biome-tools-qc:dev}"
PLATFORM="${STAMINA_BIOME_DOCKER_PLATFORM:-}"
HOST_ROOT="${STAMINA_BIOME_HOST_REPO_ROOT:-}"
CONT_ROOT="${STAMINA_BIOME_CONTAINER_REPO_ROOT:-/work}"
HOST_UID="${STAMINA_BIOME_HOST_UID:-}"
HOST_GID="${STAMINA_BIOME_HOST_GID:-}"
HOST_OS="${STAMINA_BIOME_HOST_OS:-Linux}"
HOST_HOME="${STAMINA_BIOME_HOST_HOME:-}"

rewrite_path() {
  local p="$1"
  if [[ "${p}" != /* ]]; then
    p="${CONT_ROOT}/${p}"
  fi
  if [[ -n "${HOST_ROOT}" ]]; then
    if [[ "${p}" == "${CONT_ROOT}" ]]; then echo "${HOST_ROOT}"; return; fi
    if [[ "${p}" == "${CONT_ROOT}/"* ]]; then echo "${HOST_ROOT}${p#${CONT_ROOT}}"; return; fi
  fi
  echo "${p}"
}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--outdir)
      flag="$1"; shift
      out="${1:-}"; [[ -n "${out}" ]] || { echo "ERROR: ${flag} requires a value" >&2; exit 2; }
      out_host="$(rewrite_path "${out}")"
      mkdir -p "${out_host}"
      args+=( "${flag}" "${out_host}" )
      shift
      ;;
    *)
      args+=( "$(rewrite_path "$1")" )
      shift
      ;;
  esac
done

docker_args=(run --rm)
[[ -n "${PLATFORM}" ]] && docker_args+=( --platform "${PLATFORM}" )
[[ -n "${HOST_UID}" && -n "${HOST_GID}" ]] && docker_args+=( --user "${HOST_UID}:${HOST_GID}" )

if [[ -n "${HOST_ROOT}" && -d "${HOST_ROOT}" ]]; then
  docker_args+=( -v "${HOST_ROOT}:${HOST_ROOT}:rw" )
fi
[[ -d "/Users" ]] && docker_args+=( -v "/Users:/Users:rw" )
[[ -d "/Volumes" ]] && docker_args+=( -v "/Volumes:/Volumes:rw" )

if [[ "${HOST_OS}" == "Darwin" ]]; then
  [[ -n "${HOST_HOME}" && -d "${HOST_HOME}" ]] && docker_args+=( -v "${HOST_HOME}:/home:rw" )
else
  [[ -d "/home" ]] && docker_args+=( -v "/home:/home:rw" )
fi

if [[ "${HOST_OS}" == "Linux" ]]; then
  [[ -d "/data" ]] && docker_args+=( -v "/data:/data:rw" )
  [[ -d "/mnt" ]] && docker_args+=( -v "/mnt:/mnt:rw" )
fi

docker_args+=( "${QC_IMAGE}" multiqc "${args[@]}" )
exec docker "${docker_args[@]}"
SH
  chmod 755 "${WRAPPER_DIR}/multiqc"

  FASTQC_WRAPPER_IN_CONTAINER="/opt/stamina-biome/wrappers/fastqc"
  MULTIQC_WRAPPER_IN_CONTAINER="/opt/stamina-biome/wrappers/multiqc"
fi

# -----------------------------
# sr_meta: Host Depletion Strategy Selector
# Automatically selects the best prebuilt .mmi index file
# Preference order: lowmem.mmi > split2G.mmi > split4G.mmi > full.mmi
# NEVER builds index on-the-fly; fails early if no .mmi exists
# -----------------------------
MINIMAP2_MMI_INJECT_VALUE=""
MINIMAP2_MMI_HOST_PATH=""
MINIMAP2_STRATEGY=""
SR_META_MINIMAP2_THREADS=""
SR_META_MINIMAP2_K=""

if [[ "${PIPELINE_KEY}" == "sr_meta" && -n "${MINIMAP2_HUMAN_REF_HOST_PATH}" && "${HOST_REMOVAL_ENABLED}" == "1" && "${DISABLE_HOST_REMOVAL}" != "1" ]]; then
  echo ""
  echo "[sr_meta] Host Depletion Strategy Selection"
  echo "--------------------------------------------------------------------------------"

  # Determine the host directory containing reference files
  if [[ -f "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
    HOST_REF_DIR="$(dirname "${MINIMAP2_HUMAN_REF_HOST_PATH}")"
  elif [[ -d "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
    HOST_REF_DIR="${MINIMAP2_HUMAN_REF_HOST_PATH}"
  else
    die "Minimap2 human reference path does not exist: ${MINIMAP2_HUMAN_REF_HOST_PATH}"
  fi

  # Define candidate .mmi files in preference order (best for low-memory first)
  # These are the prebuilt indices that should exist at the reference location
  declare -a MMI_CANDIDATES=(
    "GRCh38.primary_assembly.genome.lowmem.mmi:lowmem:Ultra low-memory index (~4.5GB)"
    "GRCh38.primary_assembly.genome.split2G.mmi:split2G:Split-2G index (~5GB)"
    "GRCh38.primary_assembly.genome.split4G.mmi:split4G:Split-4G index (~7GB)"
    "GRCh38.primary_assembly.genome.mmi:full:Full index (~7.1GB, requires ~8GB+ RAM)"
  )

  echo "[strategy] Searching for prebuilt .mmi files in: ${HOST_REF_DIR}"

  # Find the best available .mmi file
  SELECTED_MMI=""
  SELECTED_STRATEGY=""
  SELECTED_DESC=""

  for candidate in "${MMI_CANDIDATES[@]}"; do
    IFS=':' read -r mmi_filename strategy desc <<< "${candidate}"
    mmi_path="${HOST_REF_DIR}/${mmi_filename}"
    if [[ -f "${mmi_path}" ]]; then
      file_size="$(ls -lh "${mmi_path}" 2>/dev/null | awk '{print $5}' || echo "?")"
      echo "[strategy]   FOUND: ${mmi_filename} (${file_size}) - ${desc}"
      if [[ -z "${SELECTED_MMI}" ]]; then
        SELECTED_MMI="${mmi_path}"
        SELECTED_STRATEGY="${strategy}"
        SELECTED_DESC="${desc}"
      fi
    else
      echo "[strategy]   not found: ${mmi_filename}"
    fi
  done

  # Fail early if no prebuilt .mmi found
  if [[ -z "${SELECTED_MMI}" ]]; then
    cat >&2 <<EOF

================================================================================
ERROR: No prebuilt minimap2 index (.mmi) found for host depletion
================================================================================

sr_meta requires a prebuilt .mmi index for host depletion. Building indices
on-the-fly is disabled because it causes memory spikes and OOM crashes.

Expected location: ${HOST_REF_DIR}/

Please build at least one of these indices:
  # Ultra low-memory (recommended for Docker with <10GB RAM):
  minimap2 -x sr -k 15 -w 5 -d GRCh38.primary_assembly.genome.lowmem.mmi GRCh38.primary_assembly.genome.fa

  # Split-2G (good for Docker with 10-12GB RAM):
  minimap2 -x sr -I 2G -d GRCh38.primary_assembly.genome.split2G.mmi GRCh38.primary_assembly.genome.fa

  # Split-4G (good for Docker with 12-16GB RAM):
  minimap2 -x sr -I 4G -d GRCh38.primary_assembly.genome.split4G.mmi GRCh38.primary_assembly.genome.fa

  # Full index (requires Docker with 16GB+ RAM):
  minimap2 -x sr -d GRCh38.primary_assembly.genome.mmi GRCh38.primary_assembly.genome.fa

To skip host depletion entirely:
  --no-host-removal

================================================================================
EOF
    exit 4
  fi

  MINIMAP2_MMI_HOST_PATH="${SELECTED_MMI}"
  MINIMAP2_STRATEGY="${SELECTED_STRATEGY}"
  MINIMAP2_MMI_INJECT_VALUE="${MINIMAP2_HUMAN_REF_CONTAINER_PATH}/$(basename "${SELECTED_MMI}")"

  echo ""
  echo "[strategy] SELECTED: $(basename "${SELECTED_MMI}")"
  echo "[strategy] Strategy: ${SELECTED_STRATEGY} - ${SELECTED_DESC}"
  echo "[strategy] Container path: ${MINIMAP2_MMI_INJECT_VALUE}"

  # -----------------------------
  # sr_meta: Minimap2 memory tuning parameters
  # Determine -t (threads), -K (batch size), and whether to use -I
  # -----------------------------

  # Default thread and batch size based on strategy and lowmem mode
  if [[ "${SR_META_LOWMEM_MODE}" == "1" ]]; then
    # Ultra-safe defaults for low-memory mode
    SR_META_MINIMAP2_THREADS="1"
    SR_META_MINIMAP2_K="50M"
  elif [[ "${MINIMAP2_STRATEGY}" == "lowmem" ]]; then
    # lowmem.mmi is already optimized, can use moderate resources
    SR_META_MINIMAP2_THREADS="2"
    SR_META_MINIMAP2_K="100M"
  elif [[ "${MINIMAP2_STRATEGY}" == "split2G" ]]; then
    SR_META_MINIMAP2_THREADS="2"
    SR_META_MINIMAP2_K="100M"
  elif [[ "${MINIMAP2_STRATEGY}" == "split4G" ]]; then
    SR_META_MINIMAP2_THREADS="2"
    SR_META_MINIMAP2_K="200M"
  else
    # Full index - need more caution
    SR_META_MINIMAP2_THREADS="2"
    SR_META_MINIMAP2_K="200M"
  fi

  # CLI overrides take precedence
  if [[ -n "${CLI_MINIMAP2_THREADS}" ]]; then
    SR_META_MINIMAP2_THREADS="${CLI_MINIMAP2_THREADS}"
    echo "[strategy] Minimap2 threads overridden via CLI: ${SR_META_MINIMAP2_THREADS}"
  fi
  if [[ -n "${CLI_MINIMAP2_K}" ]]; then
    SR_META_MINIMAP2_K="${CLI_MINIMAP2_K}"
    echo "[strategy] Minimap2 batch size (-K) overridden via CLI: ${SR_META_MINIMAP2_K}"
  fi

  echo "[strategy] Minimap2 params: -t ${SR_META_MINIMAP2_THREADS} -K ${SR_META_MINIMAP2_K}"
  echo "--------------------------------------------------------------------------------"
  echo ""
fi

# -----------------------------
# sr_meta: Create minimap2 shim for memory tuning
# -----------------------------
# The shim intercepts minimap2 calls and injects memory-safe parameters:
# - -t <N> to control thread count (reduces memory from parallel processing)
# - -K <SIZE> to control query batch size (reduces peak memory)
# The shim preserves exit codes and logs for diagnostics.
MINIMAP2_SHIM_IN_CONTAINER=""
MINIMAP2_SHIM_DIR=""

if [[ "${PIPELINE_KEY}" == "sr_meta" && -n "${SR_META_MINIMAP2_THREADS}" && "${HOST_REMOVAL_ENABLED}" == "1" && "${DISABLE_HOST_REMOVAL}" != "1" ]]; then
  MINIMAP2_SHIM_DIR="$(mktemp -d "${TMP_DIR}/minimap2_shim.XXXXXX")"
  chmod 755 "${MINIMAP2_SHIM_DIR}"

  # Create the minimap2 shim script
  cat > "${MINIMAP2_SHIM_DIR}/minimap2" <<SHIM_EOF
#!/usr/bin/env bash
# STAMINA-BIOME minimap2 shim for sr_meta host depletion
# Injects memory-safe parameters without modifying the module
# Generated by run_in_container.sh

set -uo pipefail

# Find real minimap2 (skip this shim directory)
SHIM_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
REAL_MINIMAP2=""

IFS=':' read -ra PATH_PARTS <<< "\$PATH"
for dir in "\${PATH_PARTS[@]}"; do
  if [[ "\${dir}" != "\${SHIM_DIR}" && -x "\${dir}/minimap2" ]]; then
    REAL_MINIMAP2="\${dir}/minimap2"
    break
  fi
done

if [[ -z "\${REAL_MINIMAP2}" ]]; then
  # Fallback: look in common locations
  for bin in /usr/local/bin/minimap2 /usr/bin/minimap2 /opt/conda/bin/minimap2; do
    if [[ -x "\${bin}" ]]; then
      REAL_MINIMAP2="\${bin}"
      break
    fi
  done
fi

if [[ -z "\${REAL_MINIMAP2}" ]]; then
  echo "[minimap2-shim] ERROR: Could not find real minimap2 binary" >&2
  exit 127
fi

# Configured parameters (injected at shim creation time)
SHIM_THREADS="${SR_META_MINIMAP2_THREADS}"
SHIM_K="${SR_META_MINIMAP2_K}"

# Parse existing arguments to detect if this is an alignment call
# We only inject parameters for alignment calls (those with -a or -ax)
IS_ALIGNMENT_CALL="0"
HAS_T_FLAG="0"
HAS_K_FLAG="0"

for arg in "\$@"; do
  case "\${arg}" in
    -a|-ax) IS_ALIGNMENT_CALL="1" ;;
    -t) HAS_T_FLAG="1" ;;
    -t[0-9]*) HAS_T_FLAG="1" ;;
    -K) HAS_K_FLAG="1" ;;
    -K[0-9]*) HAS_K_FLAG="1" ;;
  esac
done

# Build final argument list
FINAL_ARGS=()

if [[ "\${IS_ALIGNMENT_CALL}" == "1" ]]; then
  echo "[minimap2-shim] Intercepting alignment call" >&2

  # Inject -t if not already specified and we have a value
  if [[ "\${HAS_T_FLAG}" == "0" && -n "\${SHIM_THREADS}" ]]; then
    FINAL_ARGS+=( -t "\${SHIM_THREADS}" )
    echo "[minimap2-shim] Injecting: -t \${SHIM_THREADS}" >&2
  fi

  # Inject -K if not already specified and we have a value
  if [[ "\${HAS_K_FLAG}" == "0" && -n "\${SHIM_K}" ]]; then
    FINAL_ARGS+=( -K "\${SHIM_K}" )
    echo "[minimap2-shim] Injecting: -K \${SHIM_K}" >&2
  fi
fi

# Append original arguments
FINAL_ARGS+=( "\$@" )

# Execute real minimap2, preserving exit code
echo "[minimap2-shim] Executing: \${REAL_MINIMAP2} \${FINAL_ARGS[*]}" >&2
exec "\${REAL_MINIMAP2}" "\${FINAL_ARGS[@]}"
SHIM_EOF
  chmod 755 "${MINIMAP2_SHIM_DIR}/minimap2"

  MINIMAP2_SHIM_IN_CONTAINER="/opt/stamina-biome/minimap2_shim"
  echo "[sr_meta] Created minimap2 shim: -t ${SR_META_MINIMAP2_THREADS} -K ${SR_META_MINIMAP2_K}"
fi

# -----------------------------
# Build normalized config
# Key difference: sr_amp uses HOST paths throughout for nested docker
# sr_meta uses container paths with proper mount points
# -----------------------------

if [[ "${PIPELINE_KEY}" == "sr_amp" ]]; then
  # sr_amp: Config normalization using HOST paths throughout
  #
  # CRITICAL INSIGHT: The sr_amp module launches nested Docker containers for QIIME2.
  # Those nested containers need HOST paths for volume mounts - they cannot use /work/...
  # paths because Docker Desktop doesn't recognize those as shareable.
  #
  # Solution: Use HOST paths in the config. This works because:
  # 1. We mount the repo at its host path: -v "${REPO_ROOT}:${REPO_ROOT}:rw"
  # 2. We mount /Users:/Users:rw (macOS)
  # 3. The module can use these paths directly for both file I/O AND nested docker mounts

  # Compute the HOST work_dir path
  CONFIG_WORK_DIR_RAW="$(jq -r '.run.work_dir // ""' "${CONFIG_ABS}" | tr -d '\r\n')"
  if [[ -z "${CONFIG_WORK_DIR_RAW}" || "${CONFIG_WORK_DIR_RAW}" == "null" ]]; then
    CONFIG_WORK_DIR_RAW="runs"
  fi

  # Convert to absolute host path
  if [[ "${CONFIG_WORK_DIR_RAW}" == /work/* ]]; then
    # Container path -> host path
    HOST_WORK_DIR="${REPO_ROOT}${CONFIG_WORK_DIR_RAW#/work}"
  elif [[ "${CONFIG_WORK_DIR_RAW}" != /* ]]; then
    # Relative path -> absolute host path
    HOST_WORK_DIR="${REPO_ROOT}/${CONFIG_WORK_DIR_RAW}"
  else
    # Already absolute - use as-is (could be host path or other absolute path)
    HOST_WORK_DIR="${CONFIG_WORK_DIR_RAW}"
  fi

  # Similarly, convert input paths to host paths
  CONFIG_FASTQ_R1="$(jq -r '.input.fastq_r1 // ""' "${CONFIG_ABS}" | tr -d '\r\n')"
  CONFIG_FASTQ_R2="$(jq -r '.input.fastq_r2 // ""' "${CONFIG_ABS}" | tr -d '\r\n')"

  convert_to_host_path() {
    local p="$1"
    if [[ -z "${p}" || "${p}" == "null" ]]; then
      echo ""
    elif [[ "${p}" == /work/* ]]; then
      echo "${REPO_ROOT}${p#/work}"
    elif [[ "${p}" != /* ]]; then
      echo "${REPO_ROOT}/${p}"
    else
      echo "${p}"
    fi
  }

  HOST_FASTQ_R1="$(convert_to_host_path "${CONFIG_FASTQ_R1}")"
  HOST_FASTQ_R2="$(convert_to_host_path "${CONFIG_FASTQ_R2}")"

  jq \
    --arg host_work_dir "${HOST_WORK_DIR}" \
    --arg host_fastq_r1 "${HOST_FASTQ_R1}" \
    --arg host_fastq_r2 "${HOST_FASTQ_R2}" \
    --argjson disable_host_removal "$( [[ "${DISABLE_HOST_REMOVAL}" == "1" ]] && echo true || echo false )" \
    '
    # Use HOST paths for run.work_dir - critical for nested docker mounts
    .run = (.run // {})
    | .run.work_dir = $host_work_dir

    # Convert input paths to host paths
    | if ($host_fastq_r1 | length) > 0 then .input.fastq_r1 = $host_fastq_r1 else . end
    | if ($host_fastq_r2 | length) > 0 then .input.fastq_r2 = $host_fastq_r2 else . end

    # Disable host removal if requested (sr_amp typically does not use this)
    | if $disable_host_removal then
        .params = (.params // {})
        | .params.common = ((.params.common // {}) | if type == "object" then . else {} end)
        | .params.common.remove_host = 0
      else . end
    ' "${CONFIG_ABS}" > "${TMP_CONFIG}"

elif [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  # sr_meta: Full normalization with container paths for resources
  # Resources are mounted at stable container paths (/refs/kraken2_db, /refs/human_genome)

  # Determine thread count (reduce in lowmem mode)
  CONFIG_THREADS="$(jq -r '.resources.threads // 8' "${CONFIG_ABS}" | tr -d '\r\n')"
  if [[ "${SR_META_LOWMEM_MODE}" == "1" && "${CONFIG_THREADS}" -gt 4 ]]; then
    CONFIG_THREADS="4"
  fi

  jq \
    --arg repo_root "${REPO_ROOT}" \
    --arg qc_image "${QC_IMAGE_NAME}" \
    --arg fastqc_bin "${FASTQC_WRAPPER_IN_CONTAINER}" \
    --arg multiqc_bin "${MULTIQC_WRAPPER_IN_CONTAINER}" \
    --argjson use_qc_wrappers "$( [[ "${USE_QC_WRAPPERS}" == "1" ]] && echo true || echo false )" \
    --arg kraken2_db_path "${KRAKEN2_DB_CONTAINER_PATH}" \
    --arg minimap2_mmi_path "${MINIMAP2_MMI_INJECT_VALUE}" \
    --argjson disable_host_removal "$( [[ "${DISABLE_HOST_REMOVAL}" == "1" ]] && echo true || echo false )" \
    --argjson lowmem_mode "$( [[ "${SR_META_LOWMEM_MODE}" == "1" ]] && echo true || echo false )" \
    --argjson threads "${CONFIG_THREADS}" \
    '
    # Helper: check if a string looks like a relative file path
    def looks_like_relative_path:
      type == "string" and
      . != "" and
      . != "null" and
      (startswith("/") | not) and
      (
        contains("/") or
        startswith("./") or startswith("../") or
        test("\\.(gz|fastq|fq|fa|fasta|fna|bam|sam|vcf|tsv|csv|json|txt|log|qza|qzv|mmi|biom|k2d)$"; "i")
      );

    def normalize_path:
      if looks_like_relative_path then "/work/" + .
      else .
      end;

    .
    # Normalize input paths to container paths
    | if .input.fastq_r1 then .input.fastq_r1 |= normalize_path else . end
    | if .input.fastq_r2 then .input.fastq_r2 |= normalize_path else . end
    | if .input.fastq_dir then .input.fastq_dir |= normalize_path else . end

    # Normalize run paths
    | .run = (.run // {})
    | .run.work_dir = (
        if (.run.work_dir // "" | tostring) == "" then "/work/runs"
        elif (.run.work_dir | startswith("/")) then .run.work_dir
        else "/work/" + .run.work_dir
        end
      )

    # Set thread count
    | .resources = (.resources // {})
    | .resources.threads = $threads

    # Inject QC wrappers if enabled
    | if $use_qc_wrappers then
        .tools = (.tools // {})
        | .tools.qc_image = (.tools.qc_image // $qc_image)
        | .tools.fastqc_bin = (if ($fastqc_bin | length) > 0 then $fastqc_bin else (.tools.fastqc_bin // null) end)
        | .tools.multiqc_bin = (if ($multiqc_bin | length) > 0 then $multiqc_bin else (.tools.multiqc_bin // null) end)
      else . end

    # Set Kraken2 DB paths to container path
    | .tools = (.tools // {})
    | .tools.kraken2 = ((.tools.kraken2 // {}) | if type == "object" then . else {} end)
    | .tools.kraken2.db = $kraken2_db_path
    | .tools.kraken2.db_classify = $kraken2_db_path

    # Set minimap2 human_mmi path
    | if ($minimap2_mmi_path | length) > 0 then
        .tools.minimap2 = ((.tools.minimap2 // {}) | if type == "object" then . else {} end)
        | .tools.minimap2.human_mmi = $minimap2_mmi_path
      else . end

    # Enable kraken2 memory-mapping in lowmem mode
    | if $lowmem_mode then
        .params = (.params // {})
        | .params.kraken2 = ((.params.kraken2 // {}) | if type == "object" then . else {} end)
        | .params.kraken2.memory_mapping = true
      else . end

    # Disable host removal if requested
    | if $disable_host_removal then
        .params = (.params // {})
        | .params.common = ((.params.common // {}) | if type == "object" then . else {} end)
        | .params.common.remove_host = 0
      else . end
    ' "${CONFIG_ABS}" > "${TMP_CONFIG}"

elif [[ "${PIPELINE_KEY}" == "lr_meta" || "${PIPELINE_KEY}" == "lr_amp" ]]; then
  # lr_meta/lr_amp: Full normalization with container paths for resources
  # Mirrors sr_meta behavior for host depletion, Kraken2 DB, and lowmem mode
  # Resources are mounted at stable container paths

  # Read host.resources configuration (same pattern as sr_meta)
  LR_KRAKEN2_DB_HOST_PATH="$(jq -r '.tools.kraken2.db // .host.resources.kraken2_db.host_path // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  LR_KRAKEN2_DB_CONTAINER_PATH="/refs/kraken2_db"
  LR_MINIMAP2_HUMAN_REF_HOST_PATH="$(jq -r '.tools.minimap2.human_mmi // .host.resources.minimap2_human_ref.host_path // empty' "${CONFIG_ABS}" | tr -d '\r\n')"
  LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH="/refs/human_genome"

  # Read host removal setting for lr_meta
  LR_HOST_REMOVAL_FROM_CONFIG="$(jq -r '
    .params.common.remove_host
    // .params.remove_host
    // .common.remove_host
    // .remove_host
    // 0
  ' "${CONFIG_ABS}" 2>/dev/null | tr -d '\r\n' || echo "0")"

  case "${LR_HOST_REMOVAL_FROM_CONFIG}" in
    1|true|yes|on) LR_HOST_REMOVAL_ENABLED="1" ;;
    *) LR_HOST_REMOVAL_ENABLED="0" ;;
  esac

  # -----------------------------
  # lr_meta: Low-memory mode detection (same as sr_meta)
  # -----------------------------
  LR_META_LOWMEM_MODE="0"
  LR_META_MINIMAP2_THREADS=""
  LR_META_MINIMAP2_K=""

  if [[ "${FORCE_LOWMEM_HOST_DEPLETION}" == "1" ]]; then
    LR_META_LOWMEM_MODE="1"
    echo ""
    echo "================================================================================"
    echo "[${PIPELINE_KEY}] LOW MEMORY MODE: Forced via CLI flag or environment variable"
    echo "================================================================================"
  elif [[ "${DOCKER_TOTAL_MEM_GB:-0}" -gt 0 && "${DOCKER_TOTAL_MEM_GB:-0}" -lt 9 ]]; then
    LR_META_LOWMEM_MODE="1"
    echo ""
    echo "================================================================================"
    echo "[${PIPELINE_KEY}] LOW MEMORY MODE: Auto-enabled (Docker memory: ${DOCKER_TOTAL_MEM_GB:-0}GB < 9GB)"
    echo "================================================================================"
  fi

  if [[ "${LR_META_LOWMEM_MODE}" == "1" ]]; then
    echo "[${PIPELINE_KEY}] Low-memory optimizations enabled:"
    echo "  - minimap2 will use reduced threads and batch size"
    echo "  - kraken2 will use memory-mapping mode (--memory-mapping)"
    echo "================================================================================"
    echo ""
  fi

  # -----------------------------
  # lr_meta: Minimap2 MMI selection (same pattern as sr_meta)
  # -----------------------------
  LR_MINIMAP2_MMI_INJECT_VALUE=""
  LR_MINIMAP2_MMI_HOST_PATH=""
  LR_MINIMAP2_STRATEGY=""

  if [[ -n "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" && "${LR_HOST_REMOVAL_ENABLED}" == "1" && "${DISABLE_HOST_REMOVAL}" != "1" ]]; then
    echo ""
    echo "[${PIPELINE_KEY}] Host Depletion Strategy Selection"
    echo "--------------------------------------------------------------------------------"

    # Determine the host directory containing reference files
    if [[ -f "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      LR_HOST_REF_DIR="$(dirname "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}")"
      # If path points directly to .mmi file, use it
      if [[ "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" == *.mmi ]]; then
        LR_MINIMAP2_MMI_HOST_PATH="${LR_MINIMAP2_HUMAN_REF_HOST_PATH}"
        LR_MINIMAP2_STRATEGY="direct"
        LR_MINIMAP2_MMI_INJECT_VALUE="${LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH}/$(basename "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}")"
        echo "[strategy] Using directly specified .mmi: $(basename "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}")"
      fi
    elif [[ -d "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      LR_HOST_REF_DIR="${LR_MINIMAP2_HUMAN_REF_HOST_PATH}"
    fi

    # If not directly specified, search for best .mmi (same order as sr_meta)
    if [[ -z "${LR_MINIMAP2_MMI_HOST_PATH}" && -n "${LR_HOST_REF_DIR:-}" && -d "${LR_HOST_REF_DIR}" ]]; then
      declare -a LR_MMI_CANDIDATES=(
        "GRCh38.primary_assembly.genome.lowmem.mmi:lowmem:Ultra low-memory index"
        "GRCh38.primary_assembly.genome.split2G.mmi:split2G:Split-2G index"
        "GRCh38.primary_assembly.genome.split4G.mmi:split4G:Split-4G index"
        "GRCh38.primary_assembly.genome.mmi:full:Full index"
      )

      echo "[strategy] Searching for prebuilt .mmi files in: ${LR_HOST_REF_DIR}"

      for candidate in "${LR_MMI_CANDIDATES[@]}"; do
        IFS=':' read -r mmi_filename strategy desc <<< "${candidate}"
        mmi_path="${LR_HOST_REF_DIR}/${mmi_filename}"
        if [[ -f "${mmi_path}" ]]; then
          file_size="$(ls -lh "${mmi_path}" 2>/dev/null | awk '{print $5}' || echo "?")"
          echo "[strategy]   FOUND: ${mmi_filename} (${file_size}) - ${desc}"
          if [[ -z "${LR_MINIMAP2_MMI_HOST_PATH}" ]]; then
            LR_MINIMAP2_MMI_HOST_PATH="${mmi_path}"
            LR_MINIMAP2_STRATEGY="${strategy}"
            LR_MINIMAP2_MMI_INJECT_VALUE="${LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH}/$(basename "${mmi_path}")"
          fi
        else
          echo "[strategy]   not found: ${mmi_filename}"
        fi
      done
    fi

    if [[ -n "${LR_MINIMAP2_MMI_HOST_PATH}" ]]; then
      echo ""
      echo "[strategy] SELECTED: $(basename "${LR_MINIMAP2_MMI_HOST_PATH}")"
      echo "[strategy] Strategy: ${LR_MINIMAP2_STRATEGY}"
      echo "[strategy] Container path: ${LR_MINIMAP2_MMI_INJECT_VALUE}"

      # Determine thread and batch size based on strategy and lowmem mode
      if [[ "${LR_META_LOWMEM_MODE}" == "1" ]]; then
        LR_META_MINIMAP2_THREADS="1"
        LR_META_MINIMAP2_K="50M"
      elif [[ "${LR_MINIMAP2_STRATEGY}" == "lowmem" ]]; then
        LR_META_MINIMAP2_THREADS="2"
        LR_META_MINIMAP2_K="100M"
      elif [[ "${LR_MINIMAP2_STRATEGY}" == "split2G" ]]; then
        LR_META_MINIMAP2_THREADS="2"
        LR_META_MINIMAP2_K="100M"
      else
        LR_META_MINIMAP2_THREADS="4"
        LR_META_MINIMAP2_K="200M"
      fi

      # CLI overrides
      if [[ -n "${CLI_MINIMAP2_THREADS}" ]]; then
        LR_META_MINIMAP2_THREADS="${CLI_MINIMAP2_THREADS}"
        echo "[strategy] Minimap2 threads overridden via CLI: ${LR_META_MINIMAP2_THREADS}"
      fi
      if [[ -n "${CLI_MINIMAP2_K}" ]]; then
        LR_META_MINIMAP2_K="${CLI_MINIMAP2_K}"
        echo "[strategy] Minimap2 batch size (-K) overridden via CLI: ${LR_META_MINIMAP2_K}"
      fi

      echo "[strategy] Minimap2 params: -t ${LR_META_MINIMAP2_THREADS} -K ${LR_META_MINIMAP2_K}"
      echo "--------------------------------------------------------------------------------"
      echo ""
    else
      echo "[strategy] No prebuilt .mmi found. Minimap2 will build index on-the-fly."
      echo "--------------------------------------------------------------------------------"
      echo ""
    fi
  fi

  # Determine thread count (reduce in lowmem mode)
  LR_CONFIG_THREADS="$(jq -r '.resources.threads // 8' "${CONFIG_ABS}" | tr -d '\r\n')"
  if [[ "${LR_META_LOWMEM_MODE}" == "1" && "${LR_CONFIG_THREADS}" -gt 4 ]]; then
    LR_CONFIG_THREADS="4"
  fi

  jq \
    --arg repo_root "${REPO_ROOT}" \
    --arg kraken2_db_path "${LR_KRAKEN2_DB_CONTAINER_PATH}" \
    --arg minimap2_mmi_path "${LR_MINIMAP2_MMI_INJECT_VALUE}" \
    --argjson disable_host_removal "$( [[ "${DISABLE_HOST_REMOVAL}" == "1" ]] && echo true || echo false )" \
    --argjson lowmem_mode "$( [[ "${LR_META_LOWMEM_MODE}" == "1" ]] && echo true || echo false )" \
    --argjson threads "${LR_CONFIG_THREADS}" \
    '
    def looks_like_relative_path:
      type == "string" and
      . != "" and
      . != "null" and
      (startswith("/") | not) and
      (contains("/") or startswith("./") or startswith("../") or
       test("\\.(gz|fastq|fq|fa|fasta|mmi|tsv|csv|json)$"; "i"));

    def normalize_path:
      if looks_like_relative_path then "/work/" + .
      else .
      end;

    .
    # Normalize input paths to container paths
    # NOTE: lr_meta only uses single-end FASTQ (.input.fastq) - no R1/R2 paired-end support
    | if .input.fastq then .input.fastq |= normalize_path else . end
    | if .input.fast5_dir then .input.fast5_dir |= normalize_path else . end
    | if .input.sample_sheet then .input.sample_sheet |= normalize_path else . end

    # Normalize run paths
    | .run = (.run // {})
    | .run.work_dir = (
        if (.run.work_dir // "" | tostring) == "" then "/work/data/outputs"
        elif (.run.work_dir | startswith("/")) then .run.work_dir
        else "/work/" + .run.work_dir
        end
      )

    # Set thread count
    | .resources = (.resources // {})
    | .resources.threads = $threads

    # Set Kraken2 DB paths to container path if available
    | if ($kraken2_db_path | length) > 0 then
        .tools = (.tools // {})
        | .tools.kraken2 = ((.tools.kraken2 // {}) | if type == "object" then . else {} end)
        | .tools.kraken2.db = $kraken2_db_path
      else . end

    # Set minimap2 human_mmi path
    | if ($minimap2_mmi_path | length) > 0 then
        .tools = (.tools // {})
        | .tools.minimap2 = ((.tools.minimap2 // {}) | if type == "object" then . else {} end)
        | .tools.minimap2.human_mmi = $minimap2_mmi_path
      else . end

    # Enable kraken2 memory-mapping in lowmem mode
    | if $lowmem_mode then
        .params = (.params // {})
        | .params.kraken2 = ((.params.kraken2 // {}) | if type == "object" then . else {} end)
        | .params.kraken2.memory_mapping = true
      else . end

    # Disable host removal if requested
    | if $disable_host_removal then
        .params = (.params // {})
        | .params.common = ((.params.common // {}) | if type == "object" then . else {} end)
        | .params.common.remove_host = 0
      else . end
    ' "${CONFIG_ABS}" > "${TMP_CONFIG}"

  # -----------------------------
  # lr_meta: Create minimap2 shim for memory tuning (same as sr_meta)
  # -----------------------------
  if [[ -n "${LR_META_MINIMAP2_THREADS}" && "${LR_HOST_REMOVAL_ENABLED}" == "1" && "${DISABLE_HOST_REMOVAL}" != "1" ]]; then
    MINIMAP2_SHIM_DIR="$(mktemp -d "${TMP_DIR}/minimap2_shim.XXXXXX")"
    chmod 755 "${MINIMAP2_SHIM_DIR}"

    cat > "${MINIMAP2_SHIM_DIR}/minimap2" <<SHIM_EOF
#!/usr/bin/env bash
# STAMINA-BIOME minimap2 shim for lr_meta host depletion
# Injects memory-safe parameters without modifying the module
# Generated by run_in_container.sh

set -uo pipefail

# Find real minimap2 (skip this shim directory)
SHIM_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
REAL_MINIMAP2=""

IFS=':' read -ra PATH_PARTS <<< "\$PATH"
for dir in "\${PATH_PARTS[@]}"; do
  if [[ "\${dir}" != "\${SHIM_DIR}" && -x "\${dir}/minimap2" ]]; then
    REAL_MINIMAP2="\${dir}/minimap2"
    break
  fi
done

if [[ -z "\${REAL_MINIMAP2}" ]]; then
  for bin in /usr/local/bin/minimap2 /usr/bin/minimap2 /opt/conda/bin/minimap2; do
    if [[ -x "\${bin}" ]]; then
      REAL_MINIMAP2="\${bin}"
      break
    fi
  done
fi

if [[ -z "\${REAL_MINIMAP2}" ]]; then
  echo "[minimap2-shim] ERROR: Could not find real minimap2 binary" >&2
  exit 127
fi

# Configured parameters (injected at shim creation time)
SHIM_THREADS="${LR_META_MINIMAP2_THREADS}"
SHIM_K="${LR_META_MINIMAP2_K}"

# Parse existing arguments to detect if this is an alignment call
IS_ALIGNMENT_CALL="0"
HAS_T_FLAG="0"
HAS_K_FLAG="0"

for arg in "\$@"; do
  case "\${arg}" in
    -a|-ax) IS_ALIGNMENT_CALL="1" ;;
    -t) HAS_T_FLAG="1" ;;
    -t[0-9]*) HAS_T_FLAG="1" ;;
    -K) HAS_K_FLAG="1" ;;
    -K[0-9]*) HAS_K_FLAG="1" ;;
  esac
done

# Build final argument list
FINAL_ARGS=()

if [[ "\${IS_ALIGNMENT_CALL}" == "1" ]]; then
  echo "[minimap2-shim] Intercepting alignment call" >&2

  # Inject -t if not already specified
  if [[ "\${HAS_T_FLAG}" == "0" && -n "\${SHIM_THREADS}" ]]; then
    FINAL_ARGS+=( -t "\${SHIM_THREADS}" )
    echo "[minimap2-shim] Injecting: -t \${SHIM_THREADS}" >&2
  fi

  # Inject -K if not already specified
  if [[ "\${HAS_K_FLAG}" == "0" && -n "\${SHIM_K}" ]]; then
    FINAL_ARGS+=( -K "\${SHIM_K}" )
    echo "[minimap2-shim] Injecting: -K \${SHIM_K}" >&2
  fi
fi

# Append original arguments
FINAL_ARGS+=( "\$@" )

echo "[minimap2-shim] Executing: \${REAL_MINIMAP2} \${FINAL_ARGS[*]}" >&2
exec "\${REAL_MINIMAP2}" "\${FINAL_ARGS[@]}"
SHIM_EOF
    chmod 755 "${MINIMAP2_SHIM_DIR}/minimap2"

    MINIMAP2_SHIM_IN_CONTAINER="/opt/stamina-biome/minimap2_shim"
    echo "[${PIPELINE_KEY}] Created minimap2 shim: -t ${LR_META_MINIMAP2_THREADS} -K ${LR_META_MINIMAP2_K}"
  fi

else
  # Other pipelines - basic normalization (fallback)
  jq \
    --arg repo_root "${REPO_ROOT}" \
    --argjson disable_host_removal "$( [[ "${DISABLE_HOST_REMOVAL}" == "1" ]] && echo true || echo false )" \
    '
    def looks_like_relative_path:
      type == "string" and
      . != "" and
      . != "null" and
      (startswith("/") | not) and
      (contains("/") or startswith("./") or startswith("../"));

    def normalize_path:
      if looks_like_relative_path then "/work/" + .
      else .
      end;

    .
    | if .input.fastq_r1 then .input.fastq_r1 |= normalize_path else . end
    | if .input.fastq_r2 then .input.fastq_r2 |= normalize_path else . end
    | if .input.fast5_dir then .input.fast5_dir |= normalize_path else . end
    | if .input.sample_sheet then .input.sample_sheet |= normalize_path else . end
    | .run = (.run // {})
    | .run.work_dir = (
        if (.run.work_dir // "" | tostring) == "" then "/work/runs"
        elif (.run.work_dir | startswith("/")) then .run.work_dir
        else "/work/" + .run.work_dir
        end
      )
    | if $disable_host_removal then
        .params = (.params // {})
        | .params.common = ((.params.common // {}) | if type == "object" then . else {} end)
        | .params.common.remove_host = 0
      else . end
    ' "${CONFIG_ABS}" > "${TMP_CONFIG}"
fi

TMP_CONFIG_IN_CONTAINER="/work${TMP_CONFIG#${REPO_ROOT}}"

# Log resolved paths
echo ""
echo "[config] Pipeline: ${PIPELINE_KEY}"
echo "[config] Normalized config: ${TMP_CONFIG}"
RESOLVED_WORK_DIR="$(jq -r '.run.work_dir // "<not set>"' "${TMP_CONFIG}")"
echo "[config]   run.work_dir = ${RESOLVED_WORK_DIR}"

# Show appropriate FASTQ config based on pipeline type
# Long-read pipelines use .input.fastq (single-end only, no R1/R2)
# Short-read pipelines may use .input.fastq_r1/.input.fastq_r2
if [[ "${PIPELINE_KEY}" == lr_* ]]; then
  RESOLVED_FASTQ="$(jq -r '.input.fastq // "<not set>"' "${TMP_CONFIG}")"
  echo "[config]   input.fastq = ${RESOLVED_FASTQ} (long-read single-end)"
else
  RESOLVED_FASTQ_R1="$(jq -r '.input.fastq_r1 // "<not set>"' "${TMP_CONFIG}")"
  echo "[config]   input.fastq_r1 = ${RESOLVED_FASTQ_R1}"
fi

if [[ "${PIPELINE_KEY}" == "sr_amp" ]]; then
  # sr_amp uses host paths for nested docker (QIIME2) compatibility
  echo "[config]   (using HOST paths for QIIME2 nested docker mounts)"
elif [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  RESOLVED_KRAKEN_DB="$(jq -r '.tools.kraken2.db // "<not set>"' "${TMP_CONFIG}")"
  RESOLVED_HUMAN_MMI="$(jq -r '.tools.minimap2.human_mmi // "<not set>"' "${TMP_CONFIG}")"
  RESOLVED_THREADS="$(jq -r '.resources.threads // "<not set>"' "${TMP_CONFIG}")"
  echo "[config]   tools.kraken2.db = ${RESOLVED_KRAKEN_DB}"
  echo "[config]   tools.minimap2.human_mmi = ${RESOLVED_HUMAN_MMI}"
  echo "[config]   resources.threads = ${RESOLVED_THREADS}"
  if [[ "${SR_META_LOWMEM_MODE}" == "1" ]]; then
    RESOLVED_KRAKEN_MM="$(jq -r '.params.kraken2.memory_mapping // false' "${TMP_CONFIG}")"
    echo "[config]   params.kraken2.memory_mapping = ${RESOLVED_KRAKEN_MM}"
  fi
elif [[ "${PIPELINE_KEY}" == "lr_meta" || "${PIPELINE_KEY}" == "lr_amp" ]]; then
  # lr_meta/lr_amp: long-read pipelines - single-end FASTQ only
  RESOLVED_KRAKEN_DB="$(jq -r '.tools.kraken2.db // "<not set>"' "${TMP_CONFIG}")"
  RESOLVED_HUMAN_MMI="$(jq -r '.tools.minimap2.human_mmi // "<not set>"' "${TMP_CONFIG}")"
  RESOLVED_THREADS="$(jq -r '.resources.threads // "<not set>"' "${TMP_CONFIG}")"
  echo "[config]   tools.kraken2.db = ${RESOLVED_KRAKEN_DB}"
  echo "[config]   tools.minimap2.human_mmi = ${RESOLVED_HUMAN_MMI}"
  echo "[config]   resources.threads = ${RESOLVED_THREADS}"
  echo "[config]   (long-read pipeline: single-end FASTQ mode, no R1/R2 pairs)"
  if [[ "${LR_META_LOWMEM_MODE:-0}" == "1" ]]; then
    RESOLVED_KRAKEN_MM="$(jq -r '.params.kraken2.memory_mapping // false' "${TMP_CONFIG}")"
    echo "[config]   params.kraken2.memory_mapping = ${RESOLVED_KRAKEN_MM}"
  fi
fi
echo ""

echo "[container] Running pipeline inside container"
echo "[container] Repo root (host): ${REPO_ROOT}"
echo "[container] Config (in-container): ${TMP_CONFIG_IN_CONTAINER}"
echo "[container] Image: ${IMAGE_NAME}"
[[ -n "${PLATFORM}" ]] && echo "[container] Platform: ${PLATFORM}"

HOST_UID="$(id -u || true)"
HOST_GID="$(id -g || true)"
HOST_HOME="${HOME}"

DOCKER_ARGS=(
  run --rm
  -e STAMINA_BIOME_IN_CONTAINER=1
  -e STAMINA_BIOME_HOST_REPO_ROOT="${REPO_ROOT}"
  -e STAMINA_BIOME_CONTAINER_REPO_ROOT="/work"
  -e STAMINA_BIOME_QC_IMAGE="${QC_IMAGE_NAME}"
  -e STAMINA_BIOME_DOCKER_PLATFORM="${PLATFORM}"
  -e STAMINA_BIOME_HOST_UID="${HOST_UID}"
  -e STAMINA_BIOME_HOST_GID="${HOST_GID}"
  -e STAMINA_BIOME_HOST_OS="${HOST_OS}"
  -e STAMINA_BIOME_HOST_HOME="${HOST_HOME}"
  -e DORADO_MODEL_DIR="${DORADO_MODEL_DIR:-}"
  -v "${REPO_ROOT}:/work:rw"
  -w "/work"
)

[[ -n "${PLATFORM}" ]] && DOCKER_ARGS+=( --platform "${PLATFORM}" )

# Also mount repo at host path for tools that need it
DOCKER_ARGS+=( -v "${REPO_ROOT}:${REPO_ROOT}:rw" )

# macOS mounts
[[ -d "/Users" ]] && DOCKER_ARGS+=( -v "/Users:/Users:rw" )
[[ -d "/Volumes" ]] && DOCKER_ARGS+=( -v "/Volumes:/Volumes:rw" )

if [[ "${HOST_OS}" == "Darwin" ]]; then
  [[ -d "${HOST_HOME}" ]] && DOCKER_ARGS+=( -v "${HOST_HOME}:/home:rw" )
elif [[ "${HOST_OS}" == "Linux" ]]; then
  [[ -d "/home" ]] && DOCKER_ARGS+=( -v "/home:/home:rw" )
  [[ -d "/data" ]] && DOCKER_ARGS+=( -v "/data:/data:rw" )
  [[ -d "/mnt" ]] && DOCKER_ARGS+=( -v "/mnt:/mnt:rw" )
fi

# -----------------------------
# sr_meta specific: mounts and resource limits
# -----------------------------
if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  # Mount Kraken2 DB to the container path
  DOCKER_ARGS+=( -v "${KRAKEN2_DB_HOST_PATH}:${KRAKEN2_DB_CONTAINER_PATH}:ro" )
  echo "[mount] Kraken2 DB: ${KRAKEN2_DB_HOST_PATH} -> ${KRAKEN2_DB_CONTAINER_PATH} (ro)"

  # Mount minimap2 human reference if configured
  if [[ -n "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
    if [[ -f "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      HOST_DIR="$(dirname "${MINIMAP2_HUMAN_REF_HOST_PATH}")"
      DOCKER_ARGS+=( -v "${HOST_DIR}:${MINIMAP2_HUMAN_REF_CONTAINER_PATH}:ro" )
    elif [[ -d "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      DOCKER_ARGS+=( -v "${MINIMAP2_HUMAN_REF_HOST_PATH}:${MINIMAP2_HUMAN_REF_CONTAINER_PATH}:ro" )
    fi
    echo "[mount] Human ref: ${MINIMAP2_HUMAN_REF_HOST_PATH} -> ${MINIMAP2_HUMAN_REF_CONTAINER_PATH} (ro)"
  fi

  # Mount minimap2 shim if created
  if [[ -n "${MINIMAP2_SHIM_IN_CONTAINER}" && -n "${MINIMAP2_SHIM_DIR}" && -d "${MINIMAP2_SHIM_DIR}" ]]; then
    DOCKER_ARGS+=( -v "${MINIMAP2_SHIM_DIR}:${MINIMAP2_SHIM_IN_CONTAINER}:ro" )
    # Prepend shim to PATH so it intercepts minimap2 calls
    DOCKER_ARGS+=( -e "PATH=${MINIMAP2_SHIM_IN_CONTAINER}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" )
    echo "[mount] Minimap2 shim: ${MINIMAP2_SHIM_DIR} -> ${MINIMAP2_SHIM_IN_CONTAINER}"
  fi

  # Resource limits for sr_meta
  # Memory limits are tuned based on the selected .mmi strategy
  if [[ "${SR_META_LOWMEM_MODE}" == "1" ]]; then
    # Lowmem mode: strict limits
    DOCKER_ARGS+=( --memory=6g --memory-swap=8g --cpus=4 )
    echo "[container] Resource limits: memory=6GB, swap=8GB, cpus=4 (lowmem mode)"
  elif [[ "${MINIMAP2_STRATEGY}" == "lowmem" || "${MINIMAP2_STRATEGY}" == "split2G" ]]; then
    # Optimized indices: moderate limits
    DOCKER_ARGS+=( --memory=8g --memory-swap=10g --cpus=4 )
    echo "[container] Resource limits: memory=8GB, swap=10GB, cpus=4"
  fi
  # Full/split4G indices: no explicit limits (use all available)
fi

# -----------------------------
# lr_meta/lr_amp specific: mounts and resource limits (mirrors sr_meta behavior)
# -----------------------------
if [[ "${PIPELINE_KEY}" == "lr_meta" || "${PIPELINE_KEY}" == "lr_amp" ]]; then
  # Mount Kraken2 DB to the container path if configured
  if [[ -n "${LR_KRAKEN2_DB_HOST_PATH}" && -d "${LR_KRAKEN2_DB_HOST_PATH}" ]]; then
    DOCKER_ARGS+=( -v "${LR_KRAKEN2_DB_HOST_PATH}:${LR_KRAKEN2_DB_CONTAINER_PATH}:ro" )
    echo "[mount] Kraken2 DB: ${LR_KRAKEN2_DB_HOST_PATH} -> ${LR_KRAKEN2_DB_CONTAINER_PATH} (ro)"
  fi

  # Mount minimap2 human reference if configured
  if [[ -n "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
    if [[ -f "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      LR_HOST_DIR="$(dirname "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}")"
      DOCKER_ARGS+=( -v "${LR_HOST_DIR}:${LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH}:ro" )
    elif [[ -d "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      DOCKER_ARGS+=( -v "${LR_MINIMAP2_HUMAN_REF_HOST_PATH}:${LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH}:ro" )
    fi
    echo "[mount] Human ref: ${LR_MINIMAP2_HUMAN_REF_HOST_PATH} -> ${LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH} (ro)"
  fi

  # Mount minimap2 shim if created
  if [[ -n "${MINIMAP2_SHIM_IN_CONTAINER:-}" && -n "${MINIMAP2_SHIM_DIR:-}" && -d "${MINIMAP2_SHIM_DIR:-}" ]]; then
    DOCKER_ARGS+=( -v "${MINIMAP2_SHIM_DIR}:${MINIMAP2_SHIM_IN_CONTAINER}:ro" )
    # Prepend shim to PATH so it intercepts minimap2 calls
    DOCKER_ARGS+=( -e "PATH=${MINIMAP2_SHIM_IN_CONTAINER}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" )
    echo "[mount] Minimap2 shim: ${MINIMAP2_SHIM_DIR} -> ${MINIMAP2_SHIM_IN_CONTAINER}"
  fi

  # Resource limits for lr_meta
  # Memory limits are tuned based on the selected .mmi strategy
  if [[ "${LR_META_LOWMEM_MODE:-0}" == "1" ]]; then
    # Lowmem mode: strict limits
    DOCKER_ARGS+=( --memory=6g --memory-swap=8g --cpus=4 )
    echo "[container] Resource limits: memory=6GB, swap=8GB, cpus=4 (lowmem mode)"
  elif [[ "${LR_MINIMAP2_STRATEGY:-}" == "lowmem" || "${LR_MINIMAP2_STRATEGY:-}" == "split2G" ]]; then
    # Optimized indices: moderate limits
    DOCKER_ARGS+=( --memory=8g --memory-swap=10g --cpus=4 )
    echo "[container] Resource limits: memory=8GB, swap=10GB, cpus=4"
  fi
  # Full/split4G indices: no explicit limits (use all available)
fi

if [[ "${NEEDS_DOCKER_SOCK}" == "1" ]]; then
  if [[ -S "/var/run/docker.sock" ]]; then
    DOCKER_ARGS+=( -v "/var/run/docker.sock:/var/run/docker.sock" )
  else
    echo "WARNING: /var/run/docker.sock not found on host; inner docker runs will not work." >&2
  fi
fi

if [[ "${USE_QC_WRAPPERS}" == "1" && -n "${WRAPPER_DIR}" ]]; then
  DOCKER_ARGS+=( -v "${WRAPPER_DIR}:/opt/stamina-biome/wrappers:ro" )
fi

# Build dispatcher command
DISPATCHER_CMD=( bash "${DISPATCHER_IN_CONTAINER}" --config "${TMP_CONFIG_IN_CONTAINER}" )
[[ "${FORCE_OVERWRITE}" == "1" ]] && DISPATCHER_CMD+=( --force-overwrite )
[[ "${DEBUG_MODE}" == "1" ]] && DISPATCHER_CMD+=( --debug )

DOCKER_ARGS+=( "${IMAGE_NAME}" "${DISPATCHER_CMD[@]}" )

# Print mount summary
echo ""
echo "================================================================================"
echo "Docker Mount Summary"
echo "================================================================================"
echo "Work directory: ${REPO_ROOT} -> /work (rw)"
if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  echo "Kraken2 DB:    ${KRAKEN2_DB_HOST_PATH} -> ${KRAKEN2_DB_CONTAINER_PATH} (ro)"
  [[ -n "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]] && echo "Human ref dir: ${MINIMAP2_HUMAN_REF_HOST_PATH} -> ${MINIMAP2_HUMAN_REF_CONTAINER_PATH} (ro)"
  if [[ -n "${MINIMAP2_MMI_HOST_PATH}" ]]; then
    echo "MMI index:     $(basename "${MINIMAP2_MMI_HOST_PATH}") (strategy: ${MINIMAP2_STRATEGY})"
    echo "Minimap2:      -t ${SR_META_MINIMAP2_THREADS} -K ${SR_META_MINIMAP2_K}"
  fi
  [[ -n "${MINIMAP2_SHIM_IN_CONTAINER}" ]] && echo "Minimap2 shim: enabled"
  [[ "${SR_META_LOWMEM_MODE}" == "1" ]] && echo "Lowmem mode:   enabled (kraken2 memory-mapping, reduced threads)"
elif [[ "${PIPELINE_KEY}" == "lr_meta" || "${PIPELINE_KEY}" == "lr_amp" ]]; then
  [[ -n "${LR_KRAKEN2_DB_HOST_PATH:-}" ]] && echo "Kraken2 DB:    ${LR_KRAKEN2_DB_HOST_PATH} -> ${LR_KRAKEN2_DB_CONTAINER_PATH} (ro)"
  [[ -n "${LR_MINIMAP2_HUMAN_REF_HOST_PATH:-}" ]] && echo "Human ref dir: ${LR_MINIMAP2_HUMAN_REF_HOST_PATH} -> ${LR_MINIMAP2_HUMAN_REF_CONTAINER_PATH} (ro)"
  if [[ -n "${LR_MINIMAP2_MMI_HOST_PATH:-}" ]]; then
    echo "MMI index:     $(basename "${LR_MINIMAP2_MMI_HOST_PATH}") (strategy: ${LR_MINIMAP2_STRATEGY:-direct})"
    echo "Minimap2:      -t ${LR_META_MINIMAP2_THREADS:-default} -K ${LR_META_MINIMAP2_K:-default}"
  fi
  [[ -n "${MINIMAP2_SHIM_IN_CONTAINER:-}" ]] && echo "Minimap2 shim: enabled"
  [[ "${LR_META_LOWMEM_MODE:-0}" == "1" ]] && echo "Lowmem mode:   enabled (kraken2 memory-mapping, reduced threads)"
fi
echo "================================================================================"
echo ""

# -----------------------------
# Preflight-only mode: show strategy and verify without running
# -----------------------------
if [[ "${PREFLIGHT_ONLY}" == "1" ]]; then
  echo "================================================================================"
  echo "PREFLIGHT ONLY - Configuration validated, not running pipeline"
  echo "================================================================================"
  if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
    echo ""
    echo "Host Depletion Configuration:"
    echo "  Strategy:       ${MINIMAP2_STRATEGY:-disabled}"
    echo "  MMI file:       ${MINIMAP2_MMI_HOST_PATH:-N/A}"
    echo "  Container path: ${MINIMAP2_MMI_INJECT_VALUE:-N/A}"
    echo "  Minimap2 args:  -t ${SR_META_MINIMAP2_THREADS:-default} -K ${SR_META_MINIMAP2_K:-default}"
    echo "  Lowmem mode:    ${SR_META_LOWMEM_MODE}"
    echo ""
    echo "To run the full pipeline:"
    echo "  ./pipelines/run_in_container.sh --config ${CONFIG_PATH}"
    if [[ "${SR_META_LOWMEM_MODE}" != "1" ]]; then
      echo ""
      echo "To run with low-memory mode:"
      echo "  ./pipelines/run_in_container.sh --config ${CONFIG_PATH} --lowmem-host-depletion"
    fi
  fi
  echo "================================================================================"
  exit 0
fi

# -----------------------------
# sr_meta: In-container preflight verification
# -----------------------------
if [[ "${PIPELINE_KEY}" == "sr_meta" && "${DRY_RUN}" != "1" && "${PREFLIGHT_ONLY}" != "1" ]]; then
  echo "[preflight] Verifying resources inside container..."

  VERIFY_PATHS=()
  VERIFY_PATHS+=( "${KRAKEN2_DB_CONTAINER_PATH}" )
  # Verify the specific .mmi file we selected
  if [[ -n "${MINIMAP2_MMI_INJECT_VALUE}" && "${HOST_REMOVAL_ENABLED}" == "1" && "${DISABLE_HOST_REMOVAL}" != "1" ]]; then
    VERIFY_PATHS+=( "${MINIMAP2_MMI_INJECT_VALUE}" )
  fi

  verify_args=(run --rm)
  [[ -n "${PLATFORM}" ]] && verify_args+=( --platform "${PLATFORM}" )
  verify_args+=( -v "${REPO_ROOT}:/work:rw" )
  verify_args+=( -v "${KRAKEN2_DB_HOST_PATH}:${KRAKEN2_DB_CONTAINER_PATH}:ro" )

  if [[ -n "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
    if [[ -f "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      local_host_dir="$(dirname "${MINIMAP2_HUMAN_REF_HOST_PATH}")"
      verify_args+=( -v "${local_host_dir}:${MINIMAP2_HUMAN_REF_CONTAINER_PATH}:ro" )
    elif [[ -d "${MINIMAP2_HUMAN_REF_HOST_PATH}" ]]; then
      verify_args+=( -v "${MINIMAP2_HUMAN_REF_HOST_PATH}:${MINIMAP2_HUMAN_REF_CONTAINER_PATH}:ro" )
    fi
  fi

  verify_args+=( "${IMAGE_NAME}" )

  verify_script="errors=0; "
  for path in "${VERIFY_PATHS[@]}"; do
    verify_script+="if [ -e '${path}' ]; then echo '[OK] ${path}'; else echo '[FAIL] ${path} NOT FOUND'; errors=\$((errors+1)); fi; "
  done
  verify_script+="exit \$errors"

  if verify_output="$(docker "${verify_args[@]}" sh -c "${verify_script}" 2>&1)"; then
    echo "${verify_output}"
    echo "[preflight] All resources verified inside container."
  else
    echo "${verify_output}"
    echo ""
    echo "ERROR: Some resources are not accessible inside the container." >&2
    echo "Check that all host paths exist and Docker Desktop file sharing is configured." >&2
    exit 1
  fi
  echo ""
fi

# Dry-run mode
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "================================================================================"
  echo "DRY RUN - Docker command that would be executed:"
  echo "================================================================================"
  echo "docker ${DOCKER_ARGS[*]}"
  echo ""
  echo "Normalized config written to: ${TMP_CONFIG}"
  echo "To inspect: cat ${TMP_CONFIG} | jq ."
  echo "================================================================================"
  exit 0
fi

# -----------------------------------------------------------------------------
# RUN CONTAINER
# -----------------------------------------------------------------------------
# Compute run directory on host to write container name
RUN_WORK_DIR_HOST="$(jq -r '.run.work_dir // empty' "${TMP_CONFIG}" | tr -d '
')"  
[[ -z "${RUN_WORK_DIR_HOST}" ]] && RUN_WORK_DIR_HOST="${REPO_ROOT}/data/outputs"
if [[ "${RUN_WORK_DIR_HOST}" == /work/* ]]; then
  RUN_WORK_DIR_HOST="${REPO_ROOT}${RUN_WORK_DIR_HOST#/work}"
fi

RUN_ID="$(jq -r '.run.run_id // empty' "${TMP_CONFIG}" | tr -d '
')"  
[[ -z "${RUN_ID}" ]] && RUN_ID="${PIPELINE_KEY}_$(date +%Y%m%d_%H%M%S)"
# Sanitize run_id (lowercase, alphanumeric + underscore/dash only)
RUN_ID="$(echo "${RUN_ID}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-' | sed 's/^-*//;s/-*$//')"

HOST_RUN_DIR="${RUN_WORK_DIR_HOST}/${RUN_ID}"

CONTAINER_NAME="stamina-biome-${PIPELINE_KEY}-$(date +%s)"

DOCKER_RUN_ARGS=(run --name "${CONTAINER_NAME}")
for ((i=2; i<${#DOCKER_ARGS[@]}; i++)); do
  DOCKER_RUN_ARGS+=( "${DOCKER_ARGS[$i]}" )
done

echo "[container] Starting container: ${CONTAINER_NAME}"
echo "[container] To monitor: docker logs -f ${CONTAINER_NAME}"

# Write container name to file for UI streaming
mkdir -p "${HOST_RUN_DIR}/logs" 2>/dev/null || true
echo "${CONTAINER_NAME}" > "${HOST_RUN_DIR}/container_name.txt"
echo "[container] Container name written to: ${HOST_RUN_DIR}/container_name.txt"
echo ""

set +e
docker "${DOCKER_RUN_ARGS[@]}"
DOCKER_EXIT_CODE=$?
set -e

if [[ "${DOCKER_EXIT_CODE}" -eq 0 ]]; then
  echo ""
  echo "[container] Pipeline completed successfully"
  docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true

  # -----------------------------------------------------------------------------
  # HOST-SIDE R POSTPROCESSING
  # R is not installed in the container; run postprocess on HOST where R is available
  # -----------------------------------------------------------------------------
  if [[ "${PIPELINE_KEY}" == "sr_meta" || "${PIPELINE_KEY}" == "sr_amp" || "${PIPELINE_KEY}" == "lr_meta" || "${PIPELINE_KEY}" == "lr_amp" ]]; then
    # Determine run directory on HOST
    RUN_WORK_DIR_HOST="$(jq -r '.run.work_dir // empty' "${TMP_CONFIG}" | tr -d '\r\n')"
    [[ -z "${RUN_WORK_DIR_HOST}" ]] && RUN_WORK_DIR_HOST="${REPO_ROOT}/data/outputs"
    # Translate container paths to host paths
    if [[ "${RUN_WORK_DIR_HOST}" == /work/* ]]; then
      RUN_WORK_DIR_HOST="${REPO_ROOT}${RUN_WORK_DIR_HOST#/work}"
    fi

    RUN_ID="$(jq -r '.run.run_id // empty' "${TMP_CONFIG}" | tr -d '\r\n')"
    [[ -z "${RUN_ID}" ]] && RUN_ID="${PIPELINE_KEY}_$(date +%Y%m%d_%H%M%S)"

    HOST_RUN_DIR="${RUN_WORK_DIR_HOST}/${RUN_ID}"
    HOST_MODULE_OUTPUTS="${HOST_RUN_DIR}/${PIPELINE_KEY}/outputs.json"
    HOST_MODULE_LOG="${HOST_RUN_DIR}/logs/${PIPELINE_KEY}.log"

    # Create a host-side config by translating container paths back to host paths
    HOST_CONFIG="${HOST_RUN_DIR}/effective_config.host.json"
    if [[ -f "${HOST_RUN_DIR}/effective_config.json" ]]; then
      # Translate /work/ paths back to host paths
      python3 - "${HOST_RUN_DIR}/effective_config.json" "${HOST_CONFIG}" "${REPO_ROOT}" <<'PYEOF'
import json, sys

src_path = sys.argv[1]
dst_path = sys.argv[2]
repo_root = sys.argv[3]

with open(src_path, "r", encoding="utf-8") as f:
    data = json.load(f)

def translate(val):
    if isinstance(val, str):
        if val.startswith("/work/"):
            return repo_root + val[5:]
        elif val.startswith("/work"):
            return repo_root + val[5:]
        return val
    elif isinstance(val, dict):
        return {k: translate(v) for k, v in val.items()}
    elif isinstance(val, list):
        return [translate(v) for v in val]
    return val

translated = translate(data)

with open(dst_path, "w", encoding="utf-8") as f:
    json.dump(translated, f, indent=2, ensure_ascii=False)
PYEOF
    fi

    R_RUNNER="${SCRIPT_DIR}/postprocess/r/run_r_postprocess.sh"
    if [[ -f "${R_RUNNER}" && -f "${HOST_MODULE_OUTPUTS}" ]]; then
      echo ""
      echo "[host] Running R postprocessing..."
      echo "[host] Config: ${HOST_CONFIG}"
      echo "[host] Outputs: ${HOST_MODULE_OUTPUTS}"

      set +e
      bash "${R_RUNNER}" --config "${HOST_CONFIG}" --outputs "${HOST_MODULE_OUTPUTS}" --module "${PIPELINE_KEY}" 2>&1 | tee -a "${HOST_MODULE_LOG}"
      R_EXIT_CODE="${PIPESTATUS[0]}"
      set -e

      if [[ "${R_EXIT_CODE}" -ne 0 ]]; then
        echo "[host] R postprocessing reported errors (exit code ${R_EXIT_CODE}), but pipeline completed successfully"
      else
        echo "[host] R postprocessing completed successfully"
      fi
    else
      echo "[host] R postprocessing skipped (runner or outputs not found)"
      [[ ! -f "${R_RUNNER}" ]] && echo "[host]   Missing: ${R_RUNNER}"
      [[ ! -f "${HOST_MODULE_OUTPUTS}" ]] && echo "[host]   Missing: ${HOST_MODULE_OUTPUTS}"
    fi
  fi

  exit 0
fi

# Container failed - gather diagnostics
echo ""
echo "================================================================================"
echo "CONTAINER FAILED - Exit code: ${DOCKER_EXIT_CODE}"
echo "================================================================================"

# Determine run directory for diagnostics
RUN_WORK_DIR="$(jq -r '.run.work_dir // empty' "${TMP_CONFIG}" | tr -d '\r\n')"
[[ -z "${RUN_WORK_DIR}" ]] && RUN_WORK_DIR="${REPO_ROOT}/runs"
RUN_WORK_DIR_HOST="${RUN_WORK_DIR}"
if [[ "${RUN_WORK_DIR}" == /work/* ]]; then
  RUN_WORK_DIR_HOST="${REPO_ROOT}${RUN_WORK_DIR#/work}"
fi

# Find latest run directory
LATEST_RUN_DIR=""
if [[ -d "${RUN_WORK_DIR_HOST}" ]]; then
  LATEST_RUN_DIR="$(ls -td "${RUN_WORK_DIR_HOST}/${PIPELINE_KEY}_"* 2>/dev/null | head -1 || true)"
fi

# sr_meta specific: capture Docker diagnostics on failure
if [[ "${PIPELINE_KEY}" == "sr_meta" ]]; then
  if [[ -n "${LATEST_RUN_DIR}" && -d "${LATEST_RUN_DIR}" ]]; then
    capture_docker_diagnostics "${LATEST_RUN_DIR}" "${CONTAINER_NAME}" "${DOCKER_EXIT_CODE}"
  else
    # Create a diagnostics file in tmp if no run dir exists
    mkdir -p "${RUN_WORK_DIR_HOST}" 2>/dev/null || true
    TMP_DIAG_DIR="${RUN_WORK_DIR_HOST}/failed_${PIPELINE_KEY}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "${TMP_DIAG_DIR}/logs" 2>/dev/null || true
    capture_docker_diagnostics "${TMP_DIAG_DIR}" "${CONTAINER_NAME}" "${DOCKER_EXIT_CODE}"
    LATEST_RUN_DIR="${TMP_DIAG_DIR}"
  fi
fi

CONTAINER_INFO="$(docker inspect "${CONTAINER_NAME}" 2>/dev/null || echo "{}")"
CONTAINER_STATE="$(echo "${CONTAINER_INFO}" | jq -r '.[0].State // {}' 2>/dev/null || echo "{}")"
OOM_KILLED="$(echo "${CONTAINER_STATE}" | jq -r '.OOMKilled // false' 2>/dev/null || echo "false")"

if [[ "${OOM_KILLED}" == "true" ]]; then
  DOCKER_MEM_INFO="$(docker system info 2>/dev/null | grep 'Total Memory' || echo "Unknown")"
  cat <<EOF

OUT OF MEMORY (OOM) KILLED

Docker Desktop memory: ${DOCKER_MEM_INFO}

To fix:
  1. Open Docker Desktop -> Settings -> Resources
  2. Increase Memory to at least 10GB (16GB recommended)
  3. Click 'Apply & Restart'

Alternative: Enable low-memory mode:
  ./pipelines/run_in_container.sh --config ${CONFIG_PATH} --lowmem-host-depletion

EOF
fi

case "${DOCKER_EXIT_CODE}" in
  125)
    echo "Exit code 125: Docker daemon error"
    echo ""
    echo "This usually means Docker Desktop crashed or became unresponsive."
    echo "Check:"
    echo "  1. Docker Desktop application - is it running?"
    echo "  2. Docker Desktop logs for error messages"
    echo "  3. System memory pressure (Activity Monitor)"
    echo ""
    if [[ "${PIPELINE_KEY}" == "sr_meta" && -n "${LATEST_RUN_DIR}" ]]; then
      echo "Docker diagnostics saved to: ${LATEST_RUN_DIR}/logs/docker_diagnostics.txt"
    fi
    ;;
  126) echo "Exit code 126: Command cannot be executed - check script permissions" ;;
  127) echo "Exit code 127: Command not found - check script path" ;;
  137) echo "Exit code 137: Container killed (SIGKILL) - likely OOM or manual kill" ;;
  139) echo "Exit code 139: Segmentation fault - possible architecture mismatch?" ;;
esac

echo ""
echo "Last 30 lines of container logs:"
echo "--------------------------------------------------------------------------------"
docker logs --tail 30 "${CONTAINER_NAME}" 2>&1 || echo "(Could not retrieve container logs - daemon may be down)"
echo "--------------------------------------------------------------------------------"

if [[ -n "${LATEST_RUN_DIR}" && -d "${LATEST_RUN_DIR}" ]]; then
  PIPELINE_LOG="${LATEST_RUN_DIR}/logs/${PIPELINE_KEY}.log"
  if [[ -f "${PIPELINE_LOG}" ]]; then
    echo ""
    echo "Pipeline log: ${PIPELINE_LOG}"
    echo "Last 20 lines:"
    echo "--------------------------------------------------------------------------------"
    tail -20 "${PIPELINE_LOG}" 2>/dev/null || true
    echo "--------------------------------------------------------------------------------"
  fi
fi

echo ""
echo "To retry: ./pipelines/run_in_container.sh --config ${CONFIG_PATH}"
if [[ "${PIPELINE_KEY}" == "sr_meta" && "${SR_META_LOWMEM_MODE}" != "1" ]]; then
  echo "To retry with low-memory mode: ./pipelines/run_in_container.sh --config ${CONFIG_PATH} --lowmem-host-depletion"
fi
echo "================================================================================"

docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true

exit "${DOCKER_EXIT_CODE}"
