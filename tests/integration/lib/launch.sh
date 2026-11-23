# shellcheck shell=bash
# The host side of a run, shared by ci/run.sh and s3/run.sh: checks the host and the
# configuration, sets the test bucket's credentials as the distributor's secrets, snapshots the
# code under test, and runs one suite in a transient tools container, which gets the resolved
# settings as a file and the GitHub token on stdin.

[[ -n ${_IT_LAUNCH_SH:-} ]] && return 0
_IT_LAUNCH_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/engine.sh"
source "$(dirname "${BASH_SOURCE[0]}")/settings.sh"

################################################################################
# Prints a run script's header comment (from line 2 to its `set` line) as its usage.
# Arguments:
#   The script's path.
# Outputs:
#   The usage on stdout.
################################################################################
launch__usage() {
  sed -n '2,/^set /p' "$1" | sed '$d; s/^# \{0,1\}//'
}

################################################################################
# Checks the host's tools, reporting every missing one.
# Returns:
#   0, or 1 when any is missing.
################################################################################
launch__check_tools() {
  local tool failed=false
  for tool in yq jq gh git ssh-add; do
    if ! command -v "$tool" > /dev/null; then
      log__error "needs $tool"
      failed=true
    fi
  done
  ! $failed
}

################################################################################
# Checks the SSH agent git pushes through.
# Returns:
#   0, or 1 when there's no agent or it holds no key.
################################################################################
launch__check_agent() {
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
# Whether podman runs rootless.
# Returns:
#   0 when it does, 1 when it doesn't or isn't installed.
################################################################################
launch__is_rootless_podman() {
  command -v podman > /dev/null &&
    [[ $(podman info --format '{{.Host.Security.Rootless}}' 2> /dev/null) == true ]]
}

################################################################################
# Picks the container engine: the configured one, else rootless podman, podman, or docker, the
# first installed. A suite that gets the engine's socket needs rootless podman.
# Arguments:
#   "socket" when the suite gets the engine's socket.
# Outputs:
#   podman or docker on stdout.
# Returns:
#   0, or 1 when no usable engine is found.
################################################################################
launch__engine() {
  local engine=""
  if config__has .containers.engine; then
    engine=$(config__get .containers.engine) || return 1
    if ! command -v "$engine" > /dev/null; then
      log__error "containers.engine is $engine, which isn't installed"
      return 1
    fi
  elif launch__is_rootless_podman; then
    engine=podman
  elif command -v podman > /dev/null; then
    engine=podman
  elif command -v docker > /dev/null; then
    engine=docker
  else
    log__error "needs podman or docker"
    return 1
  fi
  # The socket lets a container start containers as whoever runs the engine; docker's is root's.
  if [[ ${1:-} == socket ]] && ! { [[ $engine == podman ]] && launch__is_rootless_podman; }; then
    log__error "these tests need rootless podman: they get the engine's socket (engine: $engine)"
    return 1
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
# Checks that every role has a remote and that it exists, reporting every missing one.
# Returns:
#   0, or 1 when a remote isn't set or doesn't exist.
################################################################################
launch__check_repos() {
  local role repo failed=false
  for role in $(config__get '.repos | keys[]'); do
    if ! repo=$(config__get ".repos.$role.remote" 2> /dev/null); then
      log__error "no $role remote: run init.sh, or set repos.$role.remote in $(config__file_user)"
      failed=true
    elif ! gh api "repos/$repo" > /dev/null 2>&1; then
      log__error "$repo not found (init.sh creates the repos)"
      failed=true
    fi
  done
  ! $failed
}

################################################################################
# Copies a role's checkout into the run directory, at the commit under test: a local checkout's
# HEAD (no uncommitted changes allowed), or a GitHub repo's ref or latest release.
# Arguments:
#   Role (one with repos.<role>.checkout), destination.
# Returns:
#   0, or 1 when the code can't be found or copied.
################################################################################
launch__snapshot() {
  local checkout
  checkout=$(config__get ".repos.$1.checkout") || return 1
  if jq -e 'has("path")' <<< "$checkout" > /dev/null; then
    launch__snapshot_path "$1" "$(jq -r .path <<< "$checkout")" "$2"
  else
    launch__snapshot_repo "$1" "$(jq -r .repo <<< "$checkout")" \
      "$(jq -r '.ref // empty' <<< "$checkout")" "$2"
  fi
}

################################################################################
# launch__snapshot from a local checkout. Relative paths start at this repo's root.
# Arguments:
#   Role, path, destination.
# Returns:
#   0, or 1 when the checkout is missing, not a git checkout, dirty, or can't be copied.
################################################################################
launch__snapshot_path() {
  local path=${2/#\~/$HOME} dir sha
  if [[ $path != /* ]]; then
    path="$(dirname "${BASH_SOURCE[0]}")/../../../$path"
  fi
  if ! dir=$(realpath "$path" 2> /dev/null) || [[ ! -d $dir ]]; then
    log__error "repos.$1.checkout: $2 not found"
    return 1
  fi
  if ! sha=$(git -C "$dir" rev-parse HEAD 2> /dev/null); then
    log__error "repos.$1.checkout: $dir isn't a git checkout"
    return 1
  fi
  if [[ -n $(git -C "$dir" status --porcelain --untracked-files=no) ]]; then
    log__error "repos.$1.checkout: $dir has uncommitted changes (the tests use the HEAD commit)"
    return 1
  fi
  # Cloned, since a git worktree's .git points outside it.
  if ! { git clone --quiet --no-checkout "$dir" "$3" &&
    git -C "$3" checkout --quiet --detach "$sha"; } 2> /dev/null; then
    log__error "repos.$1.checkout: can't copy $dir's HEAD ($sha) into the run directory"
    return 1
  fi
  log__info "$1: ${sha:0:7} from $dir"
}

################################################################################
# launch__snapshot from a GitHub repo, fetched anonymously over HTTPS with its history.
# Arguments:
#   Role, owner/name, ref (empty: the latest release), destination.
# Returns:
#   0, or 1 when there's no release or the ref can't be fetched.
################################################################################
launch__snapshot_repo() {
  local ref=$3
  if [[ -z $ref ]] && ! ref=$(gh release view -R "$2" --json tagName -q .tagName 2> /dev/null); then
    log__error "repos.$1.checkout: $2 has no release; set repos.$1.checkout.ref"
    return 1
  fi
  if ! { git init --quiet "$4" &&
    GIT_TERMINAL_PROMPT=0 git -C "$4" fetch --quiet "https://github.com/$2.git" "$ref" &&
    git -C "$4" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD; } 2> /dev/null
  then
    log__error "repos.$1.checkout: can't fetch $2 at $ref"
    return 1
  fi
  log__info "$1: $(git -C "$4" rev-parse --short HEAD) from $2 at $ref"
}

################################################################################
# Writes the run's settings for the container: the configuration, and the run's own values
# under .run.
# Arguments:
#   Run id, run directory, output directory, the engine command in the container (empty when
#   it has none), the file.
# Returns:
#   0, or 1 when it can't be written.
################################################################################
launch__settings() {
  config__build || return 1
  if ! jq --arg id "$1" --arg share "$2" --arg out "$3" --arg engine "$4" \
    '.run = {id: $id, share_dir: $share, output_dir: $out, artifacts_dir: "\($out)/artifacts",
      engine: (if $engine == "" then null else $engine end)}' \
    <<< "$IT_CONFIG_JSON" > "$5"; then
    log__error "can't write $5"
    return 1
  fi
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
  printf '%s\n' -v "$sock:/run/engine.sock" -e CONTAINER_HOST=unix:///run/engine.sock
}

################################################################################
# Stops the podman service and deletes the run directory.
# Arguments:
#   Run directory, then the engine and tools image once known (to delete root-owned leftovers
#   docker can leave).
################################################################################
launch__cleanup() {
  if [[ -f $1/engine.pid ]]; then kill "$(< "$1/engine.pid")" 2> /dev/null; fi
  [[ -d $1 ]] || return 0
  rm -rf "$1" 2> /dev/null && return 0
  [[ -n $2 && -n $3 ]] || return 0
  IT_ENGINE=$2 engine__run -v "$1:/run-dir" "$3" find /run-dir -mindepth 1 -delete
  rmdir "$1" 2> /dev/null || log__info "warning: couldn't remove $1"
}

################################################################################
# One of the test bucket's credentials: from the credentials file s3/init-aws.sh writes when
# there is one, else the environment.
# Arguments:
#   Variable name (AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY).
# Outputs:
#   The value on stdout, empty when missing.
################################################################################
launch__s3_credential() {
  local field=${1#AWS_} file
  file=$(config__file_state_s3_credentials)
  # Never falling back to the environment when the file exists: it may hold an admin's.
  if [[ -f $file ]]; then
    jq -r ".${field,,} // empty" "$file"
  else
    printf '%s' "${!1:-}"
  fi
}

################################################################################
# Checks the test bucket's settings and credentials are there. Reports every missing one.
# Returns:
#   0, or 1 when any is missing.
################################################################################
launch__check_s3() {
  local name failed=false
  for name in .s3.bucket .s3.region .s3.url; do
    config__get "$name" > /dev/null || failed=true
  done
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z $(launch__s3_credential "$name") ]]; then
      log__error "needs $name (the test bucket's credentials): run s3/init-aws.sh"
      failed=true
    fi
  done
  ! $failed
}

################################################################################
# Sets the test bucket's credentials as the distributor's secrets. Secrets reach gh on stdin
# only; the tools container never sees them.
# Returns:
#   0, or 1 when a secret wasn't set.
################################################################################
launch__set_s3_secrets() {
  local repo name
  repo=$(config__get .repos.distributor.remote) || return 1
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if ! launch__s3_credential "$name" | gh secret set "$name" -R "$repo"; then
      log__error "can't set $name on $repo"
      return 1
    fi
  done
}

################################################################################
# Runs one suite: the bats files under <suite>/cases in a transient tools container, after
# checking everything the run needs and reporting every problem at once. Results (TAP) go to
# stdout and <output_dir>/<run id>/report.tap, next to settings.json and artifacts/.
# Arguments:
#   Suite, --engine-socket to give the container the user's rootless podman (optional), then
#   test names and bats options.
# Returns:
#   bats' exit status, or 1 when the run couldn't start.
################################################################################
launch__run() {
  local suite=$1 socket="" root id run_dir engine="" token image out role sock status
  local failed=false
  local -a options checkouts=()
  shift
  if [[ ${1:-} == --engine-socket ]]; then
    socket=socket
    shift
  fi
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  launch__check_tools || return 1
  # Merged once here, for every config__get below and in the scripts this one runs.
  config__build || return 1

  id=$(date -u +%Y%m%dT%H%M%SZ)
  # /dev/shm: RAM-backed, and a short path for the engine socket.
  run_dir=/dev/shm/distributor-it-$id
  if ! mkdir -m 700 "$run_dir"; then
    log__error "can't create $run_dir"
    return 1
  fi
  # shellcheck disable=SC2064 # the values are fixed now
  trap "launch__cleanup '$run_dir'" EXIT

  launch__check_agent || failed=true
  token=$(launch__token) || failed=true
  engine=$(launch__engine $socket) || failed=true
  launch__check_repos || failed=true
  launch__check_s3 || failed=true
  image=$(config__get .containers.images.tools) || failed=true
  out=$(config__get .output_dir) || failed=true
  out=${out/#\~/$HOME}/$id
  for role in $(config__get '.repos | to_entries[] | select(.value.checkout) | .key'); do
    launch__snapshot "$role" "$run_dir/src/$role" || failed=true
    checkouts+=(-v "$run_dir/src/$role:/src/$role:ro")
  done
  if $failed; then
    log__error "nothing was run: fix the above first"
    return 1
  fi
  launch__set_s3_secrets || return 1
  # shellcheck disable=SC2064 # the values are fixed now
  trap "launch__cleanup '$run_dir' '$engine' '$image'" EXIT

  if ! mkdir -p "$out/artifacts"; then
    log__error "can't create $out"
    return 1
  fi
  options=()
  if [[ -n $socket ]]; then
    sock=$(launch__engine_socket "$run_dir") || return 1
    mapfile -t options <<< "$sock"
  fi
  launch__settings "$id" "$run_dir" "$out" "${socket:+podman-remote}" "$out/settings.json" ||
    return 1
  log__info "run $id ($suite, $engine); report: $out/report.tap"

  # Ctrl-C reaches the container through the engine, which stops the running test and runs the
  # teardowns; this script and tee wait for that instead of quitting under it.
  trap 'log__info "interrupted: waiting for the tests to tear down"' INT TERM
  printf '%s\n' "$token" | IT_ENGINE=$engine engine__run -i \
    --tmpfs /tmp:exec \
    -v "$root:/suite:ro" \
    -v "$out/settings.json:$(settings__file):ro" \
    -v "$run_dir:$run_dir" -v "$out:$out" \
    "${checkouts[@]}" \
    -v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock \
    "${options[@]}" "$image" bash /suite/run-in-container.sh "$suite" "$@" |
    tee -i "$out/report.tap"
  status=${PIPESTATUS[1]}
  log__info "report: $out/report.tap"
  return "$status"
}
