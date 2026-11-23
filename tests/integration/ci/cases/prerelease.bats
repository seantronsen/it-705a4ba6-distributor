# GitHub prereleases are ignored: no state entry, no issue.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a prerelease is ignored" {
  local role=fixture repo
  repo=$(settings__get ".repos.$role.remote")
  crafted__release "$role" v9.0.0-rc1 --prerelease "$(suite__repo_name "$repo") 9.0.0"
  poll__run > /dev/null
  wait__check "no state entry" test "$(state__release_status "$repo" v9.0.0-rc1)" = absent
  wait__check "no issue" \
    test "$(distributor__issue_count "Rejected release: $repo@v9.0.0-rc1")" = 0
}
