#!/usr/bin/env bash
# Commit a run's results to state: applies them onto the latest branch tip, checks the state
# against its schema, and pushes, retrying when another push lands first. Commits nothing when
# the state is unchanged.
#
#   commit-state.sh [result.json|delta.json]...
#
# CI only: needs a checkout that can push, and the runner's GITHUB_* variables.
#
# Environment: GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_REF_NAME,
#   GITHUB_WORKFLOW.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/github.sh"

################################################################################
# Records the results and pushes the state. A function, so bash has read all of it before the
# reset below rewrites this file.
# Arguments:
#   [result.json|delta.json]...
################################################################################
main() {
  local attempt
  base__env_require GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_REF_NAME \
    GITHUB_WORKFLOW
  if [[ $# -eq 0 ]]; then
    log__info 'Nothing to record.'
    return
  fi
  cd "$ROOT" || exit 1
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  for attempt in $(seq 1 3); do
    git fetch --quiet origin "$GITHUB_REF_NAME"
    git reset --quiet --hard FETCH_HEAD
    scripts/record.sh state "$@"
    scripts/validate.sh schemas/state.schema.json state/state.json
    git add state/
    if git diff --cached --quiet; then
      log__info 'State unchanged.'
      return
    fi
    git commit --quiet -m "state: $GITHUB_WORKFLOW $(github__current_run_url)"
    git push --quiet origin "HEAD:$GITHUB_REF_NAME" && return
    log__info "Push failed (attempt $attempt); retrying on the latest state."
  done
  log__fatal "couldn't push the state after 3 attempts"
}

main "$@"
