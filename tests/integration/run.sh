#!/usr/bin/env bash
# Runs the distributor's integration tests (cases/*.bats) against the throwaway repos.
#
#   tests/integration/run.sh                        every test
#   tests/integration/run.sh retention noop         these tests (file names, .bats optional)
#   tests/integration/run.sh --filter 'deny'        bats options pass through
#
# Everything runs in one transient tools container (bats, gh, git, gpg); the install checks run
# in sibling containers through the host engine's socket. The GitHub token reaches the container
# on stdin only; git pushes over SSH through the host's agent. Logs go to stderr; the results
# (TAP) go to stdout and to <output_dir>/<run id>/report.tap.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib/log.sh"
source "$HERE/lib/config.sh"
source "$HERE/lib/engine.sh"

#######################################
# Fails unless a local checkout exists and has no uncommitted changes to tracked files (its
# HEAD commit is what gets tested).
# Arguments:
#   Path.
# Outputs:
#   The absolute path on stdout.
#######################################
checkout_path() {
  local dir
  dir=$(realpath "${1/#\~/$HOME}") || log__die "$1: not found"
  git -C "$dir" rev-parse --git-dir > /dev/null 2>&1 || log__die "$dir: not a git checkout"
  [[ -z $(git -C "$dir" status --porcelain --untracked-files=no) ]] ||
    log__die "$dir: uncommitted changes (the suite tests the HEAD commit)"
  echo "$dir"
}

#######################################
# Checks the host and gathers what the container needs: tools, settings, engine, token, and
# the SSH agent.
# Globals:
#   Sets IT_ENGINE (for engine__run), and DISTRIBUTOR_DIR, TESTBED_DIR, TOOLS_IMAGE, OUTPUT_DIR,
#   TOKEN, and ENV_ARGS (the container's -e options).
#######################################
prepare_environment() {
  local scopes distributor testbed service2
  command -v yq > /dev/null || log__die "needs yq"
  command -v gh > /dev/null || log__die "needs gh, logged in (gh auth login)"

  DISTRIBUTOR_DIR=$(checkout_path "$(config__get .checkouts.distributor)") || exit 1
  TESTBED_DIR=$(checkout_path "$(config__get .checkouts.testbed)") || exit 1
  TOOLS_IMAGE=$(config__get .images.tools docker.io/library/fedora:42) || exit 1
  OUTPUT_DIR=$(config__get .output_dir /tmp/distributor-it) || exit 1

  IT_ENGINE=$(config__get .engine) || exit 1
  if [[ -z $IT_ENGINE ]]; then
    if command -v podman > /dev/null; then IT_ENGINE=podman; else IT_ENGINE=docker; fi
  fi
  [[ $IT_ENGINE == podman || $IT_ENGINE == docker ]] || log__die "engine: podman or docker"
  command -v "$IT_ENGINE" > /dev/null || log__die "needs $IT_ENGINE"

  TOKEN=$(gh auth token) || log__die "gh isn't logged in (gh auth login)"
  # Classic tokens list their scopes; fine-grained ones don't, and are checked by use.
  scopes=$(GH_TOKEN=$TOKEN gh api -i user 2> /dev/null | tr -d '\r' |
    sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: //p')
  if [[ -n $scopes && ,${scopes// /}, != *,repo,* ]]; then
    log__die "the gh token needs the repo scope (gh auth refresh -s repo)"
  fi
  if [[ -n $scopes && ,${scopes// /}, != *,workflow,* ]]; then
    log__die "the gh token needs the workflow scope (gh auth refresh -s workflow)"
  fi

  [[ -S ${SSH_AUTH_SOCK:-} ]] ||
    log__die "git pushes over SSH: start an ssh-agent holding a key GitHub accepts"

  distributor=$(config__repo distributor) || exit 1
  testbed=$(config__repo testbed) || exit 1
  service2=$(config__repo service2) || exit 1
  ENV_ARGS=(
    -e "IT_DISTRIBUTOR_REPO=$distributor"
    -e "IT_TESTBED_REPO=$testbed"
    -e "IT_SERVICE2_REPO=$service2"
    -e "IT_TOOLS_IMAGE=$TOOLS_IMAGE"
    -e "IT_DEBIAN_IMAGE=$(config__get .images.debian docker.io/library/debian:13)"
    -e "IT_TIMEOUT=$(config__get .timeout 3600)"
    -e "IT_POLL_INTERVAL=$(config__get .poll_interval 10)"
    -e "IT_KEEP=$(config__get .keep false)"
  )
}

#######################################
# Gives the tools container access to the host's engine, for sibling containers: a private
# podman API service on a socket in the run directory, or docker's own socket.
# Globals:
#   IT_ENGINE; sets SERVICE_PID (podman) and ENGINE_ARGS (the container's options for it).
# Arguments:
#   Run directory.
#######################################
share_engine() {
  local sock
  if [[ $IT_ENGINE == podman ]]; then
    sock=$1/engine.sock
    podman system service --time=0 "unix://$sock" &
    SERVICE_PID=$!
    for _ in {1..50}; do [[ -S $sock ]] && break; sleep 0.1; done
    [[ -S $sock ]] || log__die "podman's API service didn't start"
    ENGINE_ARGS=(-v "$sock:/run/engine.sock" -e CONTAINER_HOST=unix:///run/engine.sock
      -e IT_ENGINE=podman-remote)
  else
    sock=/var/run/docker.sock
    if [[ ${DOCKER_HOST:-} == unix://* ]]; then
      sock=${DOCKER_HOST#unix://}
    elif [[ -n ${DOCKER_HOST:-} ]]; then
      log__die "DOCKER_HOST must be a unix socket"
    fi
    ENGINE_ARGS=(-v "$sock:/run/engine.sock" -e DOCKER_HOST=unix:///run/engine.sock
      -e IT_ENGINE=docker)
  fi
}

#######################################
# Stops the podman service and deletes the run directory (keys, seed clones, downloads).
# Globals:
#   RUN_DIR, SERVICE_PID, IT_ENGINE, TOOLS_IMAGE
#######################################
# shellcheck disable=SC2317,SC2329 # runs from the EXIT trap
cleanup() {
  [[ -n ${SERVICE_PID:-} ]] && kill "$SERVICE_PID" 2> /dev/null
  [[ -d ${RUN_DIR:-} ]] || return 0
  rm -rf "$RUN_DIR" 2> /dev/null && return 0
  # Root-owned leftovers (a docker container killed before handing files back).
  engine__run -v "$RUN_DIR:/run-dir" "$TOOLS_IMAGE" find /run-dir -mindepth 1 -delete
  rmdir "$RUN_DIR" 2> /dev/null || log__info "warning: couldn't remove $RUN_DIR"
}

main() {
  local id out status
  case ${1:-} in -h | --help)
    sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
    exit 0
    ;;
  esac
  prepare_environment

  id=$(date -u +%Y%m%dT%H%M%SZ)
  # /dev/shm: RAM-backed, and a short path for the engine socket.
  RUN_DIR=/dev/shm/distributor-it-$id
  out=$OUTPUT_DIR/$id
  mkdir -m 700 "$RUN_DIR" "$RUN_DIR/dnf-cache" || log__die "can't create $RUN_DIR"
  mkdir -p "$out" || log__die "can't create $out"
  trap cleanup EXIT
  share_engine "$RUN_DIR"
  log__info "run $id ($IT_ENGINE); report: $out/report.tap"

  # Ctrl-C reaches the container through the engine, which stops the running test and runs
  # the teardowns; this script and tee wait for that instead of quitting under it.
  trap 'log__info "interrupted: waiting for the tests to tear down"' INT TERM
  printf '%s\n' "$TOKEN" | engine__run -i \
    --tmpfs /tmp:exec \
    -v "$RUN_DIR:$RUN_DIR" -e "IT_SHARE_DIR=$RUN_DIR" \
    -v "$RUN_DIR/dnf-cache:/var/cache/libdnf5" \
    -v "$HERE:/suite:ro" \
    -v "$DISTRIBUTOR_DIR:/src/distributor:ro" -v "$TESTBED_DIR:/src/testbed:ro" \
    -v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    "${ENGINE_ARGS[@]}" "${ENV_ARGS[@]}" \
    "$TOOLS_IMAGE" bash /suite/run-in-container.sh "$@" | tee -i "$out/report.tap"
  status=${PIPESTATUS[1]}
  log__info "report: $out/report.tap"
  exit "$status"
}

main "$@"
