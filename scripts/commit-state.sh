#!/usr/bin/env bash
# Commit a run's results to state: applies them onto the latest branch tip, checks the state
# against its schema, and pushes, retrying when another push lands first. Commits nothing when
# the state is unchanged.
#
#   commit-state.sh [result.json|delta.json]...
#
# CI only: needs a checkout that can push, and the runner's GITHUB_* variables.
source "$(dirname "$0")/lib.sh"

# A function, so bash has read all of it before the reset below rewrites this file.
main() {
  local attempt
  if [[ $# -eq 0 ]]; then
    log 'Nothing to record.'
    return
  fi
  cd "$ROOT"
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  for attempt in $(seq 1 3); do
    git fetch --quiet origin "$GITHUB_REF_NAME"
    git reset --quiet --hard FETCH_HEAD
    scripts/record.sh state "$@"
    scripts/validate.sh state/state.schema.json state/state.json
    git add state/
    if git diff --cached --quiet; then
      log 'State unchanged.'
      return
    fi
    git commit --quiet -m "state: $GITHUB_WORKFLOW $(run_url)"
    git push --quiet origin "HEAD:$GITHUB_REF_NAME" && return
    log "Push failed (attempt $attempt); retrying on the latest state."
  done
  die "couldn't push the state after 3 attempts"
}

main "$@"
