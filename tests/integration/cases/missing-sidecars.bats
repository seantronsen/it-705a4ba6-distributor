# A release without its signature sidecars is rejected once, with one issue, and not reprocessed.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  lifecycle__reset
}

@test "a release missing its sidecars is rejected once" {
  local repo at
  repo=$(suite__service2_repo)
  github__release_create "$repo" v1.0.0
  distributor__poll > /dev/null
  wait__check "rejected" test "$(distributor__release_status "$repo" v1.0.0)" = rejected
  wait__check "a missing reason per sidecar" distributor__state_has --arg k "$repo@v1.0.0" \
    '[.[$k].reasons[] | select(startswith("missing "))] | length == 4'
  wait__check "one open issue" \
    test "$(distributor__issue_count "Rejected release: $repo@v1.0.0" OPEN)" = 1
  at=$(distributor__state | jq -r --arg k "$repo@v1.0.0" '.[$k].at')
  distributor__poll > /dev/null
  wait__check "not processed again" distributor__state_has --arg k "$repo@v1.0.0" --arg at "$at" \
    '.[$k].at == $at'
  wait__check "still one issue" \
    test "$(distributor__issue_count "Rejected release: $repo@v1.0.0")" = 1
}
