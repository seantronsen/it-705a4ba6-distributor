# GitHub prereleases are ignored: no state entry, no issue.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  lifecycle__reset
}

@test "a prerelease is ignored" {
  local repo
  repo=$(suite__service2_repo)
  crafted__release "$repo" v9.0.0-rc1 --prerelease "$(suite__repo_name "$repo") 9.0.0"
  distributor__poll > /dev/null
  wait__check "no state entry" test "$(distributor__release_status "$repo" v9.0.0-rc1)" = absent
  wait__check "no issue" \
    test "$(distributor__issue_count "Rejected release: $repo@v9.0.0-rc1")" = 0
}
