# shellcheck shell=bash
# The distributor's workflows besides poll (keyring, rekey): dispatching one and finding its runs.

[[ -n ${_IT_WORKFLOW_SH:-} ]] && return 0
_IT_WORKFLOW_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

################################################################################
# The newest run of a workflow, optionally of one trigger.
# Arguments:
#   Workflow file (e.g. keyring.yml), event (optional, e.g. push).
# Outputs:
#   The run id on stdout (0 when there is none).
################################################################################
workflow__latest() {
  gh api "repos/$(suite__distributor_repo)/actions/workflows/$1/runs" -X GET -f per_page=1 \
    ${2:+-f "event=$2"} -q '.workflow_runs[0].id // 0'
}

################################################################################
# Whether a workflow has a run newer than a given one.
# Arguments:
#   Workflow file, run id, event (optional).
# Returns:
#   0 when it has, 1 otherwise.
################################################################################
workflow__has_run_after() {
  (($(workflow__latest "$1" "${3:-}") > $2))
}

################################################################################
# Waits for a workflow's next run after a given one to start and finish.
# Arguments:
#   Workflow file, run id, event (optional).
# Outputs:
#   The new run's id on stdout.
# Returns:
#   0, or 1 when it didn't start or finish.
################################################################################
workflow__wait_next() {
  local repo id
  repo=$(suite__distributor_repo)
  wait__until "$1: a new run" workflow__has_run_after "$@" || return 1
  id=$(workflow__latest "$1" "${3:-}")
  log__info "$1 run: https://github.com/$repo/actions/runs/$id"
  github__run_wait "$repo" "$id" > /dev/null || return 1
  echo "$id"
}

################################################################################
# Dispatches a workflow and waits for it to finish.
# Arguments:
#   Workflow file.
# Outputs:
#   The run id on stdout.
# Returns:
#   0, or 1 when it didn't start or finish.
################################################################################
workflow__run() {
  local before
  before=$(workflow__latest "$1")
  if ! gh workflow run "$1" -R "$(suite__distributor_repo)" --ref main > /dev/null; then
    log__error "can't dispatch $1"
    return 1
  fi
  workflow__wait_next "$1" "$before"
}
