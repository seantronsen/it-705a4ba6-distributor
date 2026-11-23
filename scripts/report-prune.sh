#!/usr/bin/env bash
# Report prune: opens a "Prune failing" issue when prune failed in this run and in the calling
# workflow's previous run, and closes it once prune succeeds. A single failure only warns: the
# next run retries it.
#
#   report-prune.sh <failed: true|false>
#
# Exits 1 when prune failed twice in a row, so the run shows it. CI only: needs the runner's
# GITHUB_* variables, and GITHUB_TOKEN.
source "$(dirname "$0")/lib.sh"

[[ $# -eq 1 && ($1 == true || $1 == false) ]] || die "usage: report-prune.sh <true|false>"
TITLE='Prune failing'
LABEL=prune-failing

# Whether a prune job failed in the calling workflow's previous completed run.
previous_failed() {
  local workflow previous failed
  # The calling workflow's file (e.g. poll.yml), from owner/repo/<path>@<ref>.
  workflow=${GITHUB_WORKFLOW_REF%@*}
  workflow=${workflow##*/}
  previous=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs" \
    -X GET -f status=completed -f per_page=1 --jq '.workflow_runs[0].id // empty')
  [[ -n $previous ]] || return 1
  failed=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$previous/jobs" \
    --jq '.jobs[] | select((.name | startswith("prune / ")) and .conclusion == "failure") | .id')
  [[ -n $failed ]]
}

if [[ $1 == false ]]; then
  issue_close "$TITLE" "$LABEL" "Prune succeeded again ([run]($(run_url)))."
  exit 0
fi
if ! previous_failed; then
  echo "::warning::Prune failed; the next run retries it."
  exit 0
fi
issue_ensure "$TITLE" "$LABEL" "Prune failed in two runs in a row. Latest: $(run_url)"
exit 1
