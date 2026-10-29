# A release signed by a key the repo key never certified fails the trust chain.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  lifecycle__reset
}

@test "a release with an uncertified signature is rejected" {
  local repo reason
  repo=$(suite__service2_repo)
  reason="trust chain or checksums.txt signature didn't verify (see the run log)"
  crafted__release "$repo" v1.0.0 --foreign "$(suite__repo_name "$repo") 1.0.0"
  distributor__poll > /dev/null
  wait__check "rejected" test "$(distributor__release_status "$repo" v1.0.0)" = rejected
  wait__check "trust chain reason" distributor__state_has --arg k "$repo@v1.0.0" \
    --arg r "$reason" '.[$k].reasons == [$r]'
  wait__check "one issue" test "$(distributor__issue_count "Rejected release: $repo@v1.0.0")" = 1
}
