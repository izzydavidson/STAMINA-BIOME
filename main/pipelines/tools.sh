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

# ---------------------------------------------------------------------------
# Raw ONT signal input helpers (lr_meta / lr_amp)
# ---------------------------------------------------------------------------

# pod5_dir_if_present <dir> [staging_dir]
# Echo the folder of .pod5 files to basecall for <dir> (the GUI's POD5 input is
# staged through the same FAST5_DIR route), else nothing. <dir> may be a MinKNOW
# folder at any level (e.g. <experiment>/<sample>/<run>/pod5): POD5 files in
# sub-folders are found, and POD5 is used even when MinKNOW also wrote the same
# reads as FAST5. POD5 files spread over several folders are gathered into
# <staging_dir> as symlinks so Dorado reads them as one folder.
pod5_dir_if_present() {
  local dir="${1:-}" stage="${2:-}" f n=0 first="" multi=0
  [[ -n "${dir}" && -d "${dir}" ]] || return 0
  if compgen -G "${dir%/}/*.pod5" >/dev/null; then
    (cd -P "${dir}" && pwd)
    return 0
  fi
  while IFS= read -r f; do
    if [[ -z "${first}" ]]; then
      first="${f%/*}"
    elif [[ "${f%/*}" != "${first}" ]]; then
      multi=1
      break
    fi
  done < <(find "${dir%/}/" -name '.*' -prune -o \( -type f -o -type l \) -name '*.pod5' -print 2>/dev/null | sort)
  [[ -n "${first}" ]] || return 0
  if [[ "${multi}" -eq 0 || -z "${stage}" ]]; then
    (cd -P "${first}" && pwd)
    return 0
  fi
  rm -rf "${stage}"
  mkdir -p "${stage}"
  while IFS= read -r f; do
    n=$(( n + 1 ))
    ln -s "${f}" "${stage}/${n}_${f##*/}"
  done < <(find "${dir%/}/" -name '.*' -prune -o \( -type f -o -type l \) -name '*.pod5' -print 2>/dev/null | sort)
  (cd -P "${stage}" && pwd)
}

# Sample rate (Hz) of the reads in <pod5_path> (a .pod5 file or a directory of
# them), or "". Tries files in order so one damaged file does not hide the rate.
pod5_sample_rate() {
  local pod5_path="${1:-}" pod5_bin="${2:-pod5}" f rate
  local -a files=()
  if [[ -d "${pod5_path}" ]]; then
    while IFS= read -r f; do files+=( "${f}" ); done < <(find -L "${pod5_path}" -maxdepth 1 -name '*.pod5' | sort | head -n 10)
  elif [[ -f "${pod5_path}" ]]; then
    files=( "${pod5_path}" )
  fi
  for f in "${files[@]+"${files[@]}"}"; do
    # Read to the end (no early awk exit) so pod5 never dies of SIGPIPE under pipefail
    # pod5 view writes scratch files in the working directory: run it from a temp dir
    rate="$({ (cd "${TMPDIR:-/tmp}" && "${pod5_bin}" view "${f}" --include sample_rate 2>/dev/null) || true; } | awk 'NR > 1 && $1 + 0 > 0 { r = int($1); exit_ok = 1 } END { if (exit_ok) print r }')"
    if [[ -n "${rate}" ]]; then echo "${rate}"; return 0; fi
  done
  echo ""
  return 0
}

# Sample rate a Dorado model expects: [run_info] sample_rate in its config.toml;
# models without one (e.g. ..._400bps_hac@v3.5.2) are 4 kHz models.
dorado_model_sample_rate() {
  local model_path="${1:-}" rate=""
  if [[ -f "${model_path}/config.toml" ]]; then
    rate="$(awk -F'=' '/^\[run_info\]/ { r = 1; next } /^\[/ { r = 0 } r && $1 ~ /sample_rate/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${model_path}/config.toml")"
  fi
  echo "${rate:-4000}"
}

# dorado_model_for_data <model_dir> <model_name> <data_rate>
# Echoes <model_name> when it matches the data's sample rate; otherwise the newest
# installed model of the same family (text before '@') that does; else nothing.
dorado_model_for_data() {
  local model_dir="${1:-}" model="${2:-}" data_rate="${3:-}" family cand best=""
  if [[ -z "${data_rate}" || ! -d "${model_dir}/${model}" ]] || \
     [[ "$(dorado_model_sample_rate "${model_dir}/${model}")" == "${data_rate}" ]]; then
    echo "${model}"; return 0
  fi
  family="${model%@*}"
  while IFS= read -r cand; do
    [[ -n "${cand}" ]] || continue
    if [[ "$(dorado_model_sample_rate "${model_dir}/${cand}")" == "${data_rate}" ]]; then
      best="${cand}"
    fi
  done < <(find "${model_dir}" -mindepth 1 -maxdepth 1 -type d -name "${family}@*" -exec basename {} \; | sort -V)
  echo "${best}"
}

# is_unbarcoded_bin <sample_id>
# True for Dorado demux's bin of reads with no recognisable barcode
# (<run>_unclassified / unclassified). It is not a sample, so the long-read
# pipelines leave it in the demux folder and carry only barcoded reads forward.
is_unbarcoded_bin() {
  [[ "${1:-}" == "unclassified" || "${1:-}" == *_unclassified ]]
}

# minimap2_index_is_multipart <minimap2_bin> <index.mmi>
# True when a prebuilt .mmi holds several parts (built with -I smaller than the genome).
# Such an index needs --split-prefix, otherwise minimap2 writes SAM with no @SQ lines
# and samtools rejects it. Probes with an empty input, so it only loads the index.
minimap2_index_is_multipart() {
  local bin="${1:-minimap2}" idx="${2:-}" msg
  [[ "${idx}" == *.mmi && -s "${idx}" ]] || return 1
  msg="$("${bin}" -t 1 -a "${idx}" /dev/null 2>&1 >/dev/null || true)"
  [[ "${msg}" == *"multi-part index"* ]]
}
