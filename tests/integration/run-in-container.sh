#!/usr/bin/env bash
# Runs inside the tools container that ci/run.sh or distro/run.sh starts; never run it by hand.
# Installs the tools, sets up GitHub access, and runs bats on one suite's tests.
#
#   run-in-container.sh <suite> [test name... | bats option...]
#
# stdin: the GitHub token (one line), so it's never in a file, the engine's record of the
# container's environment, or a command line.
set -uo pipefail

# shellcheck source=lib/log.sh
source /suite/lib/log.sh

################################################################################
# Installs the suites' tools with apt, plus the engine client when the container has the host
# engine's socket.
# Globals:
#   IT_ENGINE (podman-remote when the container has the socket)
################################################################################
install_tools() {
  local packages=(bats ca-certificates gh git gnupg jq openssh-client rpm)
  if [[ ${IT_ENGINE:-} == podman-remote ]]; then packages+=(podman-remote); fi
  if ! { apt-get update -qq && apt-get install -y -qq --no-install-recommends "${packages[@]}"; } \
    > /dev/null 2>&1; then
    log__fatal "apt couldn't install the tools"
  fi
}

################################################################################
# GitHub access for git (gh already has GH_TOKEN): over SSH through the host's agent, with
# github.com's host keys taken from GitHub's API (over TLS) instead of trusted on first use.
################################################################################
setup_github_access() {
  install -d -m 700 ~/.ssh
  if ! gh api meta -q '.ssh_keys[] | "github.com " + .' > ~/.ssh/known_hosts; then
    log__fatal "can't fetch github.com's SSH host keys"
  fi
  # No .gitconfig: the checkout copies may belong to another user, and detached HEADs are fine.
  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o BatchMode=yes"
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
  export GIT_CONFIG_KEY_1=advice.detachedHead GIT_CONFIG_VALUE_1=false
}

main() {
  local suite=${1:-} cases files=() options=() status bats_pid
  cases=/suite/$suite/cases
  [[ -n $suite && -d $cases ]] || log__fatal "no suite '$suite'"
  shift
  IFS= read -r GH_TOKEN || true
  [[ -n $GH_TOKEN ]] || log__fatal "no GitHub token on stdin"
  export GH_TOKEN
  install_tools
  setup_github_access
  while (($#)); do
    case $1 in
      -f | --filter | --filter-tags | --filter-status)
        options+=("$1" "${2:-}")
        shift 2 || log__fatal "$1 needs a value"
        ;;
      -*)
        options+=("$1")
        shift
        ;;
      *)
        files+=("$cases/${1%.bats}.bats")
        shift
        ;;
    esac
  done
  ((${#files[@]})) || files=("$cases")
  if [[ -f $cases/setup_suite.bash ]]; then
    options+=(--setup-suite-file "$cases/setup_suite.bash")
  fi
  # Live log lines from tests: bats captures a test's stderr, so open a descriptor to the real
  # one and name it for log.sh.
  exec 9>&2
  export IT_LOG_FD=9
  # The engine's init forwards Ctrl-C to this shell only. Pass it to the whole process group, as
  # a terminal would, so the running test stops and bats runs the teardowns. bats needs SIGINT's
  # default handling back: a background job of a script starts with it ignored.
  env --default-signal=INT bats --formatter tap --timing "${options[@]}" "${files[@]}" &
  bats_pid=$!
  trap 'trap "" INT TERM; kill -INT 0' INT TERM
  wait "$bats_pid"
  status=$?
  # A signal ends the first wait early; the second collects bats' exit status.
  if kill -0 "$bats_pid" 2> /dev/null; then
    wait "$bats_pid"
    status=$?
  fi
  exit "$status"
}

main "$@"
