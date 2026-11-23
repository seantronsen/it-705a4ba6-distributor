# shellcheck shell=bash
# The distributor's poll runs: finding them, dispatching them, and downloading the repositories
# a run published.

[[ -n ${_IT_POLL_SH:-} ]] && return 0
_IT_POLL_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../github.sh"
source "$(dirname "${BASH_SOURCE[0]}")/workflow.sh"

################################################################################
# The poll run a push of a commit triggered.
# Arguments:
#   Commit SHA.
# Outputs:
#   The run id on stdout, or nothing yet.
################################################################################
poll__push_run() {
  gh api "repos/$(settings__get .repos.distributor.remote)/actions/workflows/poll.yml/runs" -X GET \
    -f event=push -f "head_sha=$1" -q '.workflow_runs[0].id // empty'
}

################################################################################
# Whether a push of a commit has triggered a poll yet.
# Arguments:
#   Commit SHA.
# Returns:
#   0 when it has, 1 otherwise.
################################################################################
poll__has_push_run() {
  [[ -n $(poll__push_run "$1") ]]
}

################################################################################
# Dispatched poll runs newer than a given run.
# Arguments:
#   Run id.
# Outputs:
#   Their ids on stdout, oldest first, one per line.
################################################################################
poll__dispatches_after() {
  gh api "repos/$(settings__get .repos.distributor.remote)/actions/workflows/poll.yml/runs" \
    -X GET -f event=workflow_dispatch -f per_page=20 \
    -q "[.workflow_runs[] | select(.id > $1) | .id] | sort | .[]"
}

################################################################################
# Whether at least <count> polls were dispatched after a given run.
# Arguments:
#   Run id, count.
# Returns:
#   0 when they were, 1 otherwise.
################################################################################
poll__has_dispatches_after() {
  (($(poll__dispatches_after "$1" | wc -l) >= $2))
}

################################################################################
# Dispatches polls without waiting for them to finish.
# Arguments:
#   How many.
# Outputs:
#   The new runs' ids on stdout, oldest first, one per line.
# Returns:
#   0, or 1 when they didn't start.
################################################################################
poll__dispatch() {
  local repo count=$1 before i id
  repo=$(settings__get .repos.distributor.remote)
  before=$(workflow__latest poll.yml)
  for ((i = 0; i < count; i++)); do
    if ! gh workflow run poll.yml -R "$repo" --ref main > /dev/null; then
      log__error "can't dispatch poll"
      return 1
    fi
  done
  wait__until "$count dispatched poll(s) start" poll__has_dispatches_after "$before" "$count" ||
    return 1
  for id in $(poll__dispatches_after "$before" | head -n "$count"); do
    log__info "poll run: https://github.com/$repo/actions/runs/$id"
    echo "$id"
  done
}

################################################################################
# Dispatches one poll and waits for it to finish.
# Outputs:
#   The run id on stdout.
# Returns:
#   0, or 1 when it didn't start or finish.
################################################################################
poll__run() {
  local id
  id=$(poll__dispatch 1) || return 1
  github__run_wait "$(settings__get .repos.distributor.remote)" "$id" > /dev/null || return 1
  echo "$id"
}
