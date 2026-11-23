#!/usr/bin/env bash
# Report prune: opens a "Prune failing" issue when prune failed in this run and in the calling
# workflow's previous run, and closes it once prune succeeds. A single failure only warns: the
# next run retries it.
#
#   report-prune.sh <failed: true|false>
#
# Exits 1 when prune failed twice in a row, so the run shows it. CI only: needs the runner's
# GITHUB_* variables, and GITHUB_TOKEN.
source "$(dirname "$0")/lib/github.sh"

TITLE='Prune failing'
LABEL=prune-failing

################################################################################
# Whether a prune job failed in the calling workflow's previous completed run.
# Globals:
#   GITHUB_WORKFLOW_REF
# Returns:
#   0 when one did, 1 otherwise.
################################################################################
has_prune_failed_before() {
  local workflow previous
  # The calling workflow's file (e.g. poll.yml), from owner/repo/<path>@<ref>.
  workflow=${GITHUB_WORKFLOW_REF%@*}
  workflow=${workflow##*/}
  previous=$(github__workflow_last_completed_run "$workflow")
  [[ -n $previous ]] && github__run_has_failed_job "$previous" "prune / "
}

################################################################################
# Closes the issue when prune succeeded; when it failed, warns, or opens the issue and fails if
# it failed in the previous run too.
# Arguments:
#   <failed: true|false>
# Returns:
#   1 when prune failed twice in a row.
################################################################################
main() {
  local failed=$1
  if [[ $failed == false ]]; then
    github__issue_close "$TITLE" "$LABEL" \
      "Prune succeeded again ([run]($(github__current_run_url)))."
    return
  fi
  if ! has_prune_failed_before; then
    echo "::warning::Prune failed; the next run retries it."
    return
  fi
  github__issue_ensure_open "$TITLE" "$LABEL" \
    "Prune failed in two runs in a row. Latest: $(github__current_run_url)"
  return 1
}

[[ $# -eq 1 && ($1 == true || $1 == false) ]] || log__fatal "usage: report-prune.sh <true|false>"
main "$@"
