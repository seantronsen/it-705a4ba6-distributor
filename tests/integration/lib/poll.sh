# shellcheck shell=bash
# The distributor side: config, polls, runs, state, and issues. Source it after common.sh.

# The test config as JSON, from a spec: {testbed_allow: [...], service2_allow: [...],
# deny: [{fingerprint, since?, reason}]}. The testbed always allows its own packages.
test_config() { # <spec json>
  jq -c --arg t "$T" --arg s "$S" '
    {repos: [
      {name: $t, allow: (["testbed", "testbed-quadlet"] + (.testbed_allow // []))}
        + (if (.deny // []) == [] then {} else {deny: .deny} end),
      {name: $s} + (if (.service2_allow // []) == [] then {} else {allow: .service2_allow} end)
    ]}' <<< "$1"
}

# Pushes a new config to the distributor and waits for the poll the push triggers.
# Sets POLL_RUN to that run's id; does nothing (POLL_RUN empty) when the config didn't change.
config_push() { # <spec json>
  local sha
  POLL_RUN=
  clone_main "$D" cfg
  test_config "$1" | yq -P -p json > "$WORK/cfg/config/repos.yaml"
  if git -C "$WORK/cfg" diff --quiet; then
    log "config: unchanged"
    return 0
  fi
  commit_all "$WORK/cfg" "it: config"
  push_main "$WORK/cfg"
  sha=$(git -C "$WORK/cfg" rev-parse HEAD)
  wait_for "poll triggered by config push ${sha:0:7}" push_run "$sha" || exit 2
  [[ -z ${CASE:-} ]] || echo "$POLL_RUN" >> "$RUN/results/$CASE.runs"
  run_wait "$POLL_RUN" > /dev/null
}

push_run() { # <sha>; sets POLL_RUN
  POLL_RUN=$(gh api "repos/$D/actions/workflows/poll.yml/runs?event=push&head_sha=$1" \
    -q '.workflow_runs[0].id // empty')
  [[ -n $POLL_RUN ]]
}

latest_poll() {
  gh api "repos/$D/actions/workflows/poll.yml/runs?per_page=1" -q '.workflow_runs[0].id // 0'
}

# Dispatches poll and prints the new run's id.
dispatch_poll() {
  local before
  before=$(latest_poll)
  gh workflow run poll.yml -R "$D" --ref main > /dev/null
  NEW_AFTER=$before
  wait_for "dispatched poll starts" new_dispatch || exit 2
  log "poll run: https://github.com/$D/actions/runs/$NEW_RUN"
  echo "$NEW_RUN" >> "$RUN/results/$CASE.runs"
  echo "$NEW_RUN"
}

new_dispatch() { # sets NEW_RUN to the newest dispatched run after NEW_AFTER
  NEW_RUN=$(gh api "repos/$D/actions/workflows/poll.yml/runs?event=workflow_dispatch&per_page=20" \
    -q "[.workflow_runs[] | select(.id > $NEW_AFTER) | .id] | min // empty")
  [[ -n $NEW_RUN ]]
}

run_completed() { # <run id>
  [[ $(gh api "repos/$D/actions/runs/$1" -q .status) == completed ]]
}

# Waits for a run to finish and prints its conclusion.
run_wait() { # <run id>
  wait_for "run $1 completes" run_completed "$1" || exit 2
  gh api "repos/$D/actions/runs/$1" -q .conclusion
}

# Conclusions of a run's jobs whose names start with <prefix> (e.g. "admit"), one per line.
job_results() { # <run id> <prefix>
  gh api --paginate "repos/$D/actions/runs/$1/jobs?per_page=100" \
    -q ".jobs[] | select(.name | startswith(\"$2\")) | .conclusion"
}

# 0 when a run has jobs starting with <prefix> and every one ended with <conclusion>.
job_all() { # <run id> <prefix> <conclusion>
  local results
  results=$(job_results "$1" "$2")
  [[ -n $results ]] && ! grep -qvx "$3" <<< "$results"
}

run_conclusion() { # <run id>
  gh api "repos/$D/actions/runs/$1" -q .conclusion
}

# Every testbed package in state, as {release, filename, status, reason} lines (JSON).
testbed_packages() {
  state_get | jq -c --arg t "$T@" \
    'to_entries[] | select(.key | startswith($t)) | .key as $k
     | (.value.packages // [])[] | {release: $k, filename, status, reason}'
}

# 0 when no testbed package is published any more.
testbed_none_published() {
  ! testbed_packages | jq -se 'any(.[]; .status == "published")' > /dev/null
}

# The deny entry that denies everything the testbed's repo key admitted.
deny_all_spec() {
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  jq -nc --arg f "$TESTBED_FPR" '{deny: [{fingerprint: $f, reason: "distributor-it"}]}'
}

# Polls once and waits for it; prints the run id.
poll_once() {
  local id
  id=$(dispatch_poll)
  run_wait "$id" > /dev/null
  echo "$id"
}

state_get() {
  gh api -H 'Accept: application/vnd.github.raw' "repos/$D/contents/state/state.json?ref=main"
}

# 0 when the jq filter, applied to state, is true.
state_has() { # [jq args...] <jq filter>
  state_get | jq -e "$@" > /dev/null
}

release_status() { # <owner/repo> <tag>
  state_get | jq -r --arg k "$1@$2" '.[$k].status // "absent"'
}

issues_get() {
  gh issue list -R "$D" --state all -L 1000 --json number,title,state,body
}

# Number of issues with this exact title (and state, if given: OPEN or CLOSED).
issue_count() { # <title> [state]
  issues_get | jq --arg t "$1" --arg s "${2:-}" \
    '[.[] | select(.title == $t and ($s == "" or .state == $s))] | length'
}
