#!/usr/bin/env bash
# =============================================================================
# STAMINA-BIOME: per-sample body-site routing (shared by pipeline modules)
# =============================================================================
# Lets one pooled/multiplexed run carry samples from different body sites
# (e.g. BC01-03 skin, BC04-06 oral, BC07-09 gut, BC10-12 vaginal) so each
# sample is classified against its own site database with its own parameters.
#
# Site sources, lowest to highest priority (later wins per sample):
#   1. global sample type (.specimen / .sample_type) - caller passes it as default
#   2. sample sheet TSV: header row with `barcode` plus `site` (or `sample_type`
#      / `body_site`) and optional `sample_name`. A headerless 2-column legacy
#      sheet is accepted; column 2 is read as the site only when it is a known
#      site name, otherwise as the sample name.
#   3. config .sample_sites object: {"barcode01": "skin", ...}
#
# Per-site resources (all optional; absent = single-site behaviour unchanged):
#   .tools.kraken2.db_by_site          {site: kraken2_db_dir}
#   .tools.kraken2.params_by_site      {site: {confidence, minimum_hit_groups}}
#   .tools.bracken.readlen_by_site     {site: readlen}
#   .tools.kraken2.comparison_db       kraken2_db_dir  (common DB, all samples)
#   .tools.kraken2.comparison_params   {confidence, minimum_hit_groups}
#
# Requires bash 4+ (associative arrays) and jq.
# =============================================================================

SITE_KNOWN_LIST="vaginal gut oral skin other"

declare -A SITE_BY_SAMPLE=()
declare -A NAME_BY_SAMPLE=()
declare -A DB_BY_SITE=()
declare -A CONF_BY_SITE=()
declare -A MHG_BY_SITE=()
declare -A BRACKEN_READLEN_BY_SITE=()
COMPARISON_DB=""
COMPARISON_CONF=""
COMPARISON_MHG=""
# 1 when at least one sample carries an explicit per-sample site
SITE_ROUTING_ACTIVE=0

_site_log() { echo "[site_routing] $*" >&2; }

# Normalise a barcode / sample identifier so GUI keys (BC01, barcode1) match
# pipeline sample IDs (barcode01, SQK-RBK114-24_barcode01).
site_normalize_key() {
  local k
  k="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ "${k}" =~ (^|[_-])(barcode|bc)0*([0-9]+)$ ]]; then
    printf 'barcode%02d' "$((10#${BASH_REMATCH[3]}))"
  else
    printf '%s' "${k}"
  fi
}

# Normalise a site label to one of SITE_KNOWN_LIST (or echo it lowercased).
site_normalize_name() {
  local s
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${s}" in
    vaginal|vagina|vag|v|vaginal_swab|cervicovaginal) echo "vaginal" ;;
    gut|stool|faecal|fecal|feces|faeces|intestinal) echo "gut" ;;
    oral|mouth|saliva|buccal|dental|plaque) echo "oral" ;;
    skin|dermal|cutaneous) echo "skin" ;;
    other|unknown|"") echo "${s:-}" ;;
    *) echo "${s}" ;;
  esac
}

site_is_known() {
  local s="${1:-}" k
  for k in ${SITE_KNOWN_LIST}; do [[ "${s}" == "${k}" ]] && return 0; done
  return 1
}

_site_set() {
  local key site
  key="$(site_normalize_key "$1")"
  site="$(site_normalize_name "$2")"
  [[ -n "${key}" && -n "${site}" ]] || return 0
  SITE_BY_SAMPLE["${key}"]="${site}"
  SITE_ROUTING_ACTIVE=1
}

_site_load_sheet() {
  local sheet="$1"
  [[ -n "${sheet}" && "${sheet}" != "null" ]] || return 0
  if [[ ! -f "${sheet}" ]]; then
    _site_log "Sample sheet not found: ${sheet} (continuing without it)"
    return 0
  fi

  local header bc_col=-1 site_col=-1 name_col=-1 i
  IFS= read -r header < "${sheet}" || true
  header="${header%$'\r'}"
  local -a cols=()
  IFS=$'\t' read -r -a cols <<< "${header}"
  for i in "${!cols[@]}"; do
    case "$(printf '%s' "${cols[$i]}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      barcode|barcode_id|sample_id) bc_col=$i ;;
      site|sample_type|body_site|specimen) site_col=$i ;;
      sample_name|name) name_col=$i ;;
    esac
  done

  local line n=0
  local -a f=()
  if [[ ${bc_col} -ge 0 ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%$'\r'}"
      [[ -n "${line}" ]] || continue
      IFS=$'\t' read -r -a f <<< "${line}"
      [[ -n "${f[$bc_col]:-}" ]] || continue
      if [[ ${name_col} -ge 0 && -n "${f[$name_col]:-}" ]]; then
        NAME_BY_SAMPLE["$(site_normalize_key "${f[$bc_col]}")"]="${f[$name_col]}"
      fi
      if [[ ${site_col} -ge 0 && -n "${f[$site_col]:-}" ]]; then
        _site_set "${f[$bc_col]}" "${f[$site_col]}"
        n=$((n + 1))
      fi
    done < <(tail -n +2 "${sheet}")
  else
    # Headerless legacy sheet: barcode<TAB>site-or-name
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line%$'\r'}"
      [[ -n "${line}" ]] || continue
      IFS=$'\t' read -r -a f <<< "${line}"
      [[ -n "${f[0]:-}" && -n "${f[1]:-}" ]] || continue
      if site_is_known "$(site_normalize_name "${f[1]}")"; then
        _site_set "${f[0]}" "${f[1]}"
        n=$((n + 1))
      else
        NAME_BY_SAMPLE["$(site_normalize_key "${f[0]}")"]="${f[1]}"
      fi
    done < "${sheet}"
  fi
  _site_log "Loaded ${n} per-sample site(s) from sample sheet: ${sheet}"
}

# site_routing_load <config.json> [sample_sheet]
site_routing_load() {
  local cfg="$1" sheet="${2:-}"
  SITE_BY_SAMPLE=(); NAME_BY_SAMPLE=(); DB_BY_SITE=(); CONF_BY_SITE=(); MHG_BY_SITE=()
  BRACKEN_READLEN_BY_SITE=(); COMPARISON_DB=""; COMPARISON_CONF=""; COMPARISON_MHG=""
  SITE_ROUTING_ACTIVE=0

  local k v site
  # Friendly names from .sample_map (barcode -> sample name)
  while IFS=$'\t' read -r k v; do
    [[ -n "${k}" ]] && NAME_BY_SAMPLE["$(site_normalize_key "${k}")"]="${v}"
  done < <(jq -r '(.sample_map // {}) | if type == "object" then to_entries[] | [.key, (.value|tostring)] | @tsv else empty end' "${cfg}" 2>/dev/null || true)

  _site_load_sheet "${sheet}"

  local n_cfg=0
  while IFS=$'\t' read -r k v; do
    [[ -n "${k}" && -n "${v}" ]] || continue
    _site_set "${k}" "${v}"
    n_cfg=$((n_cfg + 1))
  done < <(jq -r '(.sample_sites // .input.sample_sites // {}) | if type == "object" then to_entries[] | [.key, (.value|tostring)] | @tsv else empty end' "${cfg}" 2>/dev/null || true)
  [[ ${n_cfg} -gt 0 ]] && _site_log "Loaded ${n_cfg} per-sample site(s) from config .sample_sites"

  while IFS=$'\t' read -r site v; do
    site="$(site_normalize_name "${site}")"
    [[ -n "${site}" && -n "${v}" && "${v}" != "null" ]] && DB_BY_SITE["${site}"]="${v}"
  done < <(jq -r '(.tools.kraken2.db_by_site // {}) | if type == "object" then to_entries[] | [.key, (.value|tostring)] | @tsv else empty end' "${cfg}" 2>/dev/null || true)

  local conf mhg
  while IFS=$'\t' read -r site conf mhg; do
    site="$(site_normalize_name "${site}")"
    [[ -n "${site}" ]] || continue
    [[ -n "${conf}" && "${conf}" != "null" ]] && CONF_BY_SITE["${site}"]="${conf}"
    [[ -n "${mhg}" && "${mhg}" != "null" ]] && MHG_BY_SITE["${site}"]="${mhg}"
  done < <(jq -r '(.tools.kraken2.params_by_site // {}) | if type == "object" then to_entries[] | [.key, ((.value.confidence // "null")|tostring), ((.value.minimum_hit_groups // "null")|tostring)] | @tsv else empty end' "${cfg}" 2>/dev/null || true)

  while IFS=$'\t' read -r site v; do
    site="$(site_normalize_name "${site}")"
    [[ -n "${site}" && -n "${v}" && "${v}" != "null" ]] && BRACKEN_READLEN_BY_SITE["${site}"]="${v}"
  done < <(jq -r '(.tools.bracken.readlen_by_site // {}) | if type == "object" then to_entries[] | [.key, (.value|tostring)] | @tsv else empty end' "${cfg}" 2>/dev/null || true)

  COMPARISON_DB="$(jq -r '.tools.kraken2.comparison_db // empty' "${cfg}" 2>/dev/null || true)"
  [[ "${COMPARISON_DB}" == "null" ]] && COMPARISON_DB=""
  COMPARISON_CONF="$(jq -r '.tools.kraken2.comparison_params.confidence // empty' "${cfg}" 2>/dev/null || true)"
  COMPARISON_MHG="$(jq -r '.tools.kraken2.comparison_params.minimum_hit_groups // empty' "${cfg}" 2>/dev/null || true)"
  [[ -n "${COMPARISON_CONF}" ]] || COMPARISON_CONF="0.05"
  [[ -n "${COMPARISON_MHG}" ]] || COMPARISON_MHG="2"

  if [[ ${SITE_ROUTING_ACTIVE} -eq 1 ]]; then
    local summary="" key
    for key in $(printf '%s\n' "${!SITE_BY_SAMPLE[@]}" | sort); do
      summary+=" ${key}=${SITE_BY_SAMPLE[$key]}"
    done
    _site_log "Per-sample sites:${summary}"
  fi
  if [[ ${#DB_BY_SITE[@]} -gt 0 ]]; then
    for site in $(printf '%s\n' "${!DB_BY_SITE[@]}" | sort); do
      _site_log "Kraken2 DB for ${site}: ${DB_BY_SITE[$site]}"
    done
  fi
  [[ -n "${COMPARISON_DB}" ]] && _site_log "Comparison DB (all samples): ${COMPARISON_DB} (confidence=${COMPARISON_CONF}, minimum_hit_groups=${COMPARISON_MHG})"
  return 0
}

# site_for_sample <sample_id> <default_site>
site_for_sample() {
  local key def="${2:-unknown}"
  key="$(site_normalize_key "${1:-}")"
  # "mixed" is a run-level mode, not a site: unmapped samples fall back to "other"
  [[ "${def}" == "mixed" ]] && def="other"
  echo "${SITE_BY_SAMPLE[${key}]:-${def}}"
}

# site_name_for_sample <sample_id>  -> friendly name or the ID itself
site_name_for_sample() {
  local key
  key="$(site_normalize_key "${1:-}")"
  echo "${NAME_BY_SAMPLE[${key}]:-${1:-}}"
}

# site_db_for <site> <fallback_db>
site_db_for() {
  local site="${1:-}" fallback="${2:-}"
  echo "${DB_BY_SITE[${site}]:-${fallback}}"
}

# site_pick_bracken_readlen <db_dir> <preferred_readlen>
# Echoes preferred if its kmer_distrib exists in db, else the largest available, else "".
site_pick_bracken_readlen() {
  local db="${1:-}" pref="${2:-}"
  [[ -n "${db}" && -d "${db}" ]] || { echo ""; return 0; }
  if [[ -n "${pref}" && "${pref}" != "auto" && -s "${db}/database${pref}mers.kmer_distrib" ]]; then
    echo "${pref}"; return 0
  fi
  local best="" f n
  shopt -s nullglob
  for f in "${db}"/database*mers.kmer_distrib; do
    n="$(basename "${f}")"; n="${n#database}"; n="${n%mers.kmer_distrib}"
    [[ "${n}" =~ ^[0-9]+$ ]] || continue
    if [[ -z "${best}" || "${n}" -gt "${best}" ]]; then best="${n}"; fi
  done
  shopt -u nullglob
  echo "${best}"
}

# site_write_samples_tsv <path> <default_site> <sample_id>...
# Writes sample_id / sample_name / site for downstream tables and plots.
site_write_samples_tsv() {
  local path="$1" def="$2"; shift 2
  mkdir -p "$(dirname "${path}")"
  {
    printf 'sample_id\tsample_name\tsite\n'
    local id
    for id in "$@"; do
      printf '%s\t%s\t%s\n' "${id}" "$(site_name_for_sample "${id}")" "$(site_for_sample "${id}" "${def}")"
    done
  } > "${path}"
}

# site_has_vaginal <default_site> <sample_id>...  -> 0 if any sample resolves to vaginal
site_has_vaginal() {
  local def="$1"; shift
  local id
  for id in "$@"; do
    [[ "$(site_for_sample "${id}" "${def}")" == "vaginal" ]] && return 0
  done
  return 1
}
