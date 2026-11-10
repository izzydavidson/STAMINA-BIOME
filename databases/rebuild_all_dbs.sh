#!/usr/bin/env bash
# databases/rebuild_all_dbs.sh
# Rebuild gut, oral and skin one after another (sequential to avoid USB I/O
# contention). Stops at the first site that fails verification or the
# before/after acceptance check; already-finished sites are skipped on re-run.
# Vaginal is not included: all of its July additions are already indexed.
#
#   bash databases/rebuild_all_dbs.sh 2>&1 | tee ~/db_rebuild_2026-11.log
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK_BASE="${WORK_BASE:-${CUSTOM_DB_BASE:-/Volumes/MyPassport/custom_db}/_rebuild_2026-11}"
for site in ${SITES:-gut oral skin}; do
  if [[ -f "${WORK_BASE}/${site}/completed" ]]; then
    echo "[$site] already completed — skipping"; continue
  fi
  echo "════════════════ $site ════════════════"
  if ! bash "${HERE}/rebuild_site_db.sh" "$site" all; then
    echo
    echo "[$site] STOPPED. Read ${WORK_BASE}/${site}/compare_report.txt and rebuild.log."
    echo "  Accept anyway:  bash ${HERE}/rebuild_site_db.sh $site record"
    echo "  Undo:           bash ${HERE}/rebuild_site_db.sh $site rollback"
    exit 1
  fi
done
echo "All sites rebuilt and validated."
