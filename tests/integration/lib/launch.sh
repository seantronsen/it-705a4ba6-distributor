# shellcheck shell=bash
# The host side of a run, shared by ci/run.sh and distro/run.sh: checks the host, snapshots the
# local checkouts, and runs one suite in a transient tools container, the GitHub token on stdin.

[[ -n ${_IT_LAUNCH_SH:-} ]] && return 0
_IT_LAUNCH_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/engine.sh"

################################################################################
# Prints an entry script's header comment (from line 2 to its `set` line) as its usage.
# Arguments:
#   The script's path.
# Outputs:
#   The usage on stdout.
################################################################################
launch__usage() {
  sed -n '2,/^set /p' "$1" | sed '$d; s/^# \{0,1\}//'
}

################################################################################
# Checks the host's tools and the SSH agent git pushes through.
# Returns:
#   0, or 1 when something is missing.
################################################################################
launch__check_host() {
  local tool
  for tool in yq gh git ssh-add; do
    if ! command -v "$tool" > /dev/null; then
      log__error "needs $tool"
      return 1
    fi
  done
  if [[ ! -S ${SSH_AUTH_SOCK:-} ]]; then
    log__error "git pushes over SSH: start an ssh-agent holding a key GitHub accepts"
    return 1
  fi
  if ! ssh-add -l > /dev/null 2>&1; then
    log__error "the SSH agent holds no key: add one GitHub accepts (ssh-add <key file>)"
    return 1
  fi
}

################################################################################
# Picks the container engine. A suite that gets the engine's socket needs rootless podman: the
# socket lets a container start containers as whoever runs the engine, and docker's is root's.
# Arguments:
#   "socket" when the suite gets the engine's socket (optional).
# Outputs:
#   podman or docker on stdout.
# Returns:
#   0, or 1 when no usable engine is found.
################################################################################
launch__engine() {
  local engine
  engine=$(config__get .engine) || return 1
  if [[ -z $engine ]]; then
    if command -v podman > /dev/null; then engine=podman; else engine=docker; fi
  fi
  if [[ $engine != podman && $engine != docker ]]; then
    log__error "engine: podman or docker, not $engine"
    return 1
  fi
  if ! command -v "$engine" > /dev/null; then
    log__error "needs $engine"
    return 1
  fi
  if [[ ${1:-} == socket ]]; then
    if [[ $engine != podman ]]; then
      log__error "these tests need rootless podman: they get the engine's socket (engine: $engine)"
      return 1
    fi
    if [[ $(podman info --format '{{.Host.Security.Rootless}}') != true ]]; then
      log__error "these tests need rootless podman: they get the engine's socket"
      return 1
    fi
  fi
  echo "$engine"
}

################################################################################
# The GitHub token from gh, checked for the repo scope.
# Outputs:
#   The token on stdout.
# Returns:
#   0, or 1 when gh isn't logged in or the token lacks the scope.
################################################################################
launch__token() {
  local token scopes
  if ! token=$(gh auth token); then
    log__error "gh isn't logged in (gh auth login)"
    return 1
  fi
  # Classic tokens list their scopes; fine-grained ones don't, and are checked by use.
  scopes=$(GH_TOKEN=$token gh api -i user 2> /dev/null | tr -d '\r' |
    sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: //p')
  if [[ -n $scopes && ,${scopes// /}, != *,repo,* ]]; then
    log__error "the gh token needs the repo scope (gh auth refresh -s repo)"
    return 1
  fi
  echo "$token"
}

################################################################################
# Copies a local checkout's HEAD commit into the run directory, so the container gets a plain
# repo whatever the checkout is (a git worktree's .git points outside it). Refuses uncommitted
# changes to tracked files: they wouldn't be tested.
# Arguments:
#   Role (distributor or testbed: checkouts.<role> in the settings), destination directory.
# Returns:
#   0, or 1 when the checkout is missing, not a git checkout, dirty, or can't be copied.
################################################################################
launch__snapshot() {
  local path dir sha
  path=$(config__get ".checkouts.$1") || return 1
  if ! dir=$(realpath "${path/#\~/$HOME}" 2> /dev/null) || [[ ! -d $dir ]]; then
    log__error "checkouts.$1: $path not found"
    return 1
  fi
  if ! sha=$(git -C "$dir" rev-parse HEAD 2> /dev/null); then
    log__error "checkouts.$1: $dir isn't a git checkout"
    return 1
  fi
  if [[ -n $(git -C "$dir" status --porcelain --untracked-files=no) ]]; then
    log__error "checkouts.$1: $dir has uncommitted changes (the tests use the HEAD commit)"
    return 1
  fi
  if ! { git clone --quiet --no-checkout "$dir" "$2" &&
    git -C "$2" checkout --quiet --detach "$sha"; } 2> /dev/null; then
    log__error "can't copy $dir's HEAD ($sha) into the run directory"
    return 1
  fi
  log__info "$1: ${sha:0:7} from $dir"
}

################################################################################
# The container's settings, checking that the repos exist.
# Outputs:
#   The container's -e options on stdout, one word per line.
# Returns:
#   0, or 1 when a setting can't be read or a repo doesn't exist.
################################################################################
launch__env() {
  local role repo
  for role in distributor testbed service2; do
    repo=$(config__repo "$role") || return 1
    if ! gh api "repos/$repo" > /dev/null 2>&1; then
      log__error "$repo not found (init.sh creates the repos)"
      return 1
    fi
    printf '%s\n' -e "IT_${role^^}_REPO=$repo"
  done
  printf '%s\n' \
    -e "IT_TIMEOUT=$(config__get .timeout 3600)" \
    -e "IT_POLL_INTERVAL=$(config__get .poll_interval 10)" \
    -e "IT_KEEP=$(config__get .keep false)" \
    -e "IT_IMAGE_FEDORA=$(config__get .images.fedora docker.io/library/fedora:42)" \
    -e "IT_IMAGE_DEBIAN=$(config__get .images.debian docker.io/library/debian:13)" \
    -e "IT_IMAGE_VERSITYGW=$(config__get .images.versitygw docker.io/versity/versitygw:v1.10.0)"
}

################################################################################
# Starts a private API service of the user's rootless podman on a socket in the run directory,
# for a suite that starts sibling containers.
# Arguments:
#   Run directory.
# Outputs:
#   The container's options for it on stdout, one word per line.
# Returns:
#   0, or 1 when the service didn't start.
################################################################################
launch__engine_socket() {
  local sock=$1/engine.sock
  # Its output goes elsewhere: this function's stdout is read to its end.
  podman system service --time=0 "unix://$sock" > /dev/null 2>&1 &
  echo $! > "$1/engine.pid"
  for _ in {1..50}; do
    [[ -S $sock ]] && break
    sleep 0.1
  done
  if [[ ! -S $sock ]]; then
    log__error "podman's API service didn't start"
    return 1
  fi
  printf '%s\n' -v "$sock:/run/engine.sock" -e CONTAINER_HOST=unix:///run/engine.sock \
    -e IT_ENGINE=podman-remote
}

################################################################################
# Stops the podman service and deletes the run directory (keys, checkout copies, the gateway's
# files).
# Arguments:
#   Run directory, engine, tools image (to delete root-owned leftovers docker can leave).
################################################################################
launch__cleanup() {
  if [[ -f $1/engine.pid ]]; then kill "$(< "$1/engine.pid")" 2> /dev/null; fi
  [[ -d $1 ]] || return 0
  rm -rf "$1" 2> /dev/null && return 0
  IT_ENGINE=$2 engine__run -v "$1:/run-dir" "$3" find /run-dir -mindepth 1 -delete
  rmdir "$1" 2> /dev/null || log__info "warning: couldn't remove $1"
}

################################################################################
# Runs one suite: the bats files under <suite>/cases in a transient tools container. The
# results (TAP) go to stdout and <output_dir>/<run id>/report.tap; files tests export go to
# <output_dir>/<run id>/artifacts.
# Arguments:
#   Suite (ci or distro), --engine-socket to give the container the user's rootless podman
#   (optional), then test names and bats options.
# Returns:
#   bats' exit status, or 1 when the run couldn't start.
################################################################################
launch__run() {
  local suite=$1 socket="" root engine token image settings sock id run_dir out role status
  local -a args
  shift
  if [[ ${1:-} == --engine-socket ]]; then
    socket=socket
    shift
  fi
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  launch__check_host || return 1
  engine=$(launch__engine $socket) || return 1
  token=$(launch__token) || return 1
  image=$(config__get .images.tools docker.io/library/debian:13) || return 1
  out=$(config__get .output_dir /tmp/distributor-it) || return 1
  settings=$(launch__env) || return 1
  mapfile -t args <<< "$settings"

  id=$(date -u +%Y%m%dT%H%M%SZ)
  # /dev/shm: RAM-backed, and a short path for the engine socket.
  run_dir=/dev/shm/distributor-it-$id
  out=$out/$id
  if ! mkdir -m 700 "$run_dir" || ! mkdir -p "$out/artifacts"; then
    log__error "can't create $run_dir or $out"
    return 1
  fi
  # shellcheck disable=SC2064 # the values are fixed now
  trap "launch__cleanup '$run_dir' '$engine' '$image'" EXIT
  for role in distributor testbed; do
    launch__snapshot "$role" "$run_dir/src/$role" || return 1
  done
  if [[ -n $socket ]]; then
    sock=$(launch__engine_socket "$run_dir") || return 1
    mapfile -t -O "${#args[@]}" args <<< "$sock"
  fi
  log__info "run $id ($suite, $engine); report: $out/report.tap"

  # Ctrl-C reaches the container through the engine, which stops the running test and runs the
  # teardowns; this script and tee wait for that instead of quitting under it.
  trap 'log__info "interrupted: waiting for the tests to tear down"' INT TERM
  printf '%s\n' "$token" | IT_ENGINE=$engine engine__run -i \
    --tmpfs /tmp:exec \
    -v "$root:/suite:ro" \
    -v "$run_dir:$run_dir" -e "IT_SHARE_DIR=$run_dir" \
    -v "$out/artifacts:$out/artifacts" -e "IT_ARTIFACTS_DIR=$out/artifacts" \
    -v "$run_dir/src/distributor:/src/distributor:ro" -v "$run_dir/src/testbed:/src/testbed:ro" \
    -v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    "${args[@]}" "$image" bash /suite/run-in-container.sh "$suite" "$@" |
    tee -i "$out/report.tap"
  status=${PIPESTATUS[1]}
  log__info "report: $out/report.tap"
  return "$status"
}
