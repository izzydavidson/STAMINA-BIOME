#!/usr/bin/env bash
# Keeps a containerised run going when Docker Desktop crashes or hangs.
#
# docker_guard_run runs the container launcher and watches the Docker engine.
# When the engine dies or stops answering, it restarts Docker Desktop and runs
# the launcher again with STAMINA_BIOME_RESUME=1, so a module that supports
# resuming (lr_meta) skips the steps and samples it already finished.
# Pipeline errors (a tool failing, bad input, ...) are never retried.
#
# Tunables (environment):
#   STAMINA_BIOME_DOCKER_RETRIES       restarts allowed per run       (default 3)
#   STAMINA_BIOME_DOCKER_CHECK_SECS    seconds between engine checks  (default 60)
#   STAMINA_BIOME_DOCKER_HANG_CHECKS   failed checks in a row = hung  (default 5)

DOCKER_GUARD_MAX_RESTARTS="${STAMINA_BIOME_DOCKER_RETRIES:-3}"
DOCKER_GUARD_CHECK_SECS="${STAMINA_BIOME_DOCKER_CHECK_SECS:-60}"
DOCKER_GUARD_HANG_CHECKS="${STAMINA_BIOME_DOCKER_HANG_CHECKS:-5}"

# Client messages that mean the engine went away mid-run
DOCKER_GUARD_ENGINE_LOST_RE='Cannot connect to the Docker daemon|error during connect|error waiting for container|Is the docker daemon running'

docker_guard_log() { echo "[docker-guard] $*"; }

# docker_responsive [timeout_secs]: true when the engine answers within the timeout
docker_responsive() {
  local limit="${1:-20}" pid i
  docker info >/dev/null 2>&1 &
  pid=$!
  for (( i = 0; i < limit; i++ )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null && return 0
      return 1
    fi
    sleep 1
  done
  kill -9 "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null
  return 1
}

# docker_restart: quit Docker Desktop (forcing it when the quit hangs) and start it again
docker_restart() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    docker_guard_log "Automatic Docker restart is only supported on macOS" >&2
    return 1
  fi
  local i
  docker_guard_log "Restarting Docker Desktop..."
  osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
  for (( i = 0; i < 30; i++ )); do
    pgrep -f com.docker.backend >/dev/null || break
    sleep 2
  done
  if pgrep -f com.docker.backend >/dev/null; then
    docker_guard_log "Docker did not quit - forcing it to stop"
    pkill -9 -f '/Applications/Docker.app/' 2>/dev/null || true
    pkill -9 -f 'com\.docker\.(backend|virtualization|build)' 2>/dev/null || true
    sleep 3
  fi
  open -a Docker || return 1
  for (( i = 0; i < 60; i++ )); do
    if docker_responsive 10; then
      docker_guard_log "Docker is running again"
      return 0
    fi
    sleep 5
  done
  docker_guard_log "Docker did not come back within 5 minutes" >&2
  return 1
}

# _guard_tree <pid>: <pid> and all of its descendants
_guard_tree() {
  local child
  echo "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do
    _guard_tree "${child}"
  done
}

# _guard_tree_uses_docker <pid>: true while a docker client runs under <pid>
_guard_tree_uses_docker() {
  local p
  for p in $(_guard_tree "$1"); do
    [[ "$(ps -o comm= -p "${p}" 2>/dev/null)" == *docker ]] && return 0
  done
  return 1
}

_guard_kill_tree() {
  local p
  for p in $(_guard_tree "$1"); do
    kill -TERM "${p}" 2>/dev/null || true
  done
}

# docker_guard_run <cmd...>: run <cmd>; on a Docker engine failure restart Docker and
# rerun it with STAMINA_BIOME_RESUME=1. Returns <cmd>'s exit code.
docker_guard_run() {
  local restarts=0 ec pid fails hung waited out
  out="$(mktemp "${TMPDIR:-/tmp}/stamina_docker_guard.XXXXXX")"
  pid=""
  # Stopping the run (Ctrl-C, kill) stops the attempt underneath too
  trap '[[ -n "${pid}" ]] && _guard_kill_tree "${pid}"; rm -f "${out}"; exit 143' TERM INT HUP

  if ! docker_responsive 20; then
    docker_guard_log "Docker is not responding before the run - restarting it"
    docker_restart || { rm -f "${out}"; return 1; }
  fi

  while :; do
    hung=0
    fails=0
    waited=0
    ( set -o pipefail; "$@" 2>&1 | tee "${out}" ) &
    pid=$!

    while kill -0 "${pid}" 2>/dev/null; do
      sleep 5
      waited=$(( waited + 5 ))
      (( waited % DOCKER_GUARD_CHECK_SECS == 0 )) || continue
      if docker_responsive 30; then
        fails=0
        continue
      fi
      fails=$(( fails + 1 ))
      docker_guard_log "Docker engine not responding (check ${fails}/${DOCKER_GUARD_HANG_CHECKS})"
      (( fails >= DOCKER_GUARD_HANG_CHECKS )) || continue
      if _guard_tree_uses_docker "${pid}"; then
        docker_guard_log "Docker is hung while the run needs it - stopping this attempt"
        hung=1
        _guard_kill_tree "${pid}"
        break
      fi
      # Nothing is using Docker right now (e.g. GPU basecalling on the host):
      # repair Docker and let the run carry on
      docker_restart || true
      fails=0
    done

    ec=0
    wait "${pid}" || ec=$?
    [[ "${ec}" -eq 0 ]] && break

    if [[ "${hung}" -eq 0 ]] && docker_responsive 30 && ! grep -Eq "${DOCKER_GUARD_ENGINE_LOST_RE}" "${out}"; then
      # Docker is fine, so the pipeline itself failed: do not retry
      break
    fi

    if (( restarts >= DOCKER_GUARD_MAX_RESTARTS )); then
      docker_guard_log "Docker failed again after ${restarts} restart(s) - giving up" >&2
      break
    fi
    restarts=$(( restarts + 1 ))
    docker_guard_log "Docker failed during the run (exit ${ec}) - restart ${restarts}/${DOCKER_GUARD_MAX_RESTARTS}, then resuming"
    if ! docker_responsive 20; then
      docker_restart || break
    fi
    export STAMINA_BIOME_RESUME=1
  done

  trap - TERM INT HUP
  rm -f "${out}"
  return "${ec}"
}
