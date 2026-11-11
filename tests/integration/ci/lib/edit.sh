# shellcheck shell=bash
# Changing files on the throwaway distributor besides its config (keys/), as one pushed commit.

[[ -n ${_IT_EDIT_SH:-} ]] && return 0
_IT_EDIT_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

################################################################################
# Runs a command in a clone of the distributor, commits what it changed, pushes, and waits for
# what the push triggers (a keys/ change: the keyring workflow). GIT_COMMITTER_DATE, when set,
# backdates the commit.
# Arguments:
#   Commit message, then the command and its arguments (run in the clone).
# Returns:
#   0, or 1 when the command, the push, or the triggered runs failed to finish.
################################################################################
edit__distributor() {
  local repo dir
  repo=$(suite__distributor_repo)
  dir=$(mktemp -d)
  git__clone "$repo" "$dir/repo" || return 1
  if ! (cd "$dir/repo" && "${@:2}"); then
    log__error "can't edit $repo: ${*:2}"
    return 1
  fi
  git__commit "$dir/repo" "it: $1" || return 1
  git__push_main "$dir/repo" "$repo" || return 1
  github__wait_idle "$repo"
}
