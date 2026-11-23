# A poll cancelled mid-run commits nothing; the next poll admits the release normally.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

################################################################################
# Cancels a poll run once admit or publish is running.
# Arguments:
#   Run id.
# Returns:
#   0 when cancelled, 1 while neither has started yet, 2 (give up) once record has started,
#   since cancelling then no longer tests a mid-run cancel.
################################################################################
cancel_mid_run() {
  local distributor jobs
  distributor=$(settings__get .repos.distributor.remote)
  jobs=$(gh api "repos/$distributor/actions/runs/$1/jobs?per_page=100" \
    -q '.jobs[] | "\(.name)\t\(.status)"')
  grep -q $'^record[^\t]*\t\(in_progress\|completed\)' <<< "$jobs" && return 2
  grep -q $'^\(admit\|publish\)[^\t]*\tin_progress' <<< "$jobs" || return 1
  gh run cancel "$1" -R "$distributor" > /dev/null
}

@test "a poll cancelled mid-run commits nothing" {
  local role=fixture repo distributor before run
  repo=$(settings__get ".repos.$role.remote")
  distributor=$(settings__get .repos.distributor.remote)
  crafted__release_create "$role" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  before=$(github__head_sha "$distributor")
  run=$(poll__dispatch 1)
  wait__until "admit or publish running in $run, then cancel" cancel_mid_run "$run"
  wait__check "run cancelled" test "$(github__run_wait "$distributor" "$run")" = cancelled
  wait__check "no state commit" test "$(github__head_sha "$distributor")" = "$before"
  wait__check "not in state" test "$(state__release_status "$repo" v1.0.0)" = absent
  poll__run > /dev/null
  wait__check "published by the next poll" \
    test "$(state__release_status "$repo" v1.0.0)" = published
}
