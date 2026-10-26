#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found on PATH: ${cmd}" >&2
    return 2
  fi
}

resolve_tool() {
  local config_path="$1"
  local jq_expr="$2"
  local default_cmd="$3"

  local configured=""
  if [[ -n "${config_path}" && -f "${config_path}" ]]; then
    configured="$(jq -r "${jq_expr} // empty" "${config_path}" 2>/dev/null || true)"
  fi

  # Treat null/empty as not set
  if [[ -n "${configured}" && "${configured}" != "null" ]]; then
    echo "${configured}"
    return 0
  fi

  # Fall back to PATH
  if command -v "${default_cmd}" >/dev/null 2>&1; then
    echo "${default_cmd}"
    return 0
  fi

  # Return empty string but with exit 0 - callers handle empty values
  # This prevents set -e from exiting the script when a tool is optional
  echo ""
  return 0
}


is_command_available() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1
}

exit_code_means_tool_missing() {
  local ec="$1"
  [[ "${ec}" -eq 127 ]]
}
