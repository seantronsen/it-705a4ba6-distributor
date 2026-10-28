# shellcheck shell=bash
# Case 1: a poll with nothing new admits nothing and commits no state.

case_main() {
  local before run
  before=$(head_sha "$D")
  run=$(poll_once)
  check "poll succeeded" test "$(run_conclusion "$run")" = success
  check "admit skipped" job_all "$run" admit skipped
  check "no state commit" test "$(head_sha "$D")" = "$before"
}
