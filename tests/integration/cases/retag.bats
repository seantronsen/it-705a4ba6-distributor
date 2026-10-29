# Packages already admitted can't come back under another tag; ship a new version instead.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  lifecycle__reset
}

@test "a retagged copy of an admitted release is rejected" {
  local repo
  repo=$(suite__service2_repo)
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  distributor__poll > /dev/null
  crafted__copy_release "$repo" v1.0.0 v1.0.0-retag
  distributor__poll > /dev/null
  wait__check "rejected" test "$(distributor__release_status "$repo" v1.0.0-retag)" = rejected
  wait__check "every package already admitted" distributor__state_has \
    --arg k "$repo@v1.0.0-retag" '.[$k].reasons | length == 2
      and all(endswith("was already admitted; ship a new patch version"))'
  wait__check "one issue" \
    test "$(distributor__issue_count "Rejected release: $repo@v1.0.0-retag")" = 1
}
