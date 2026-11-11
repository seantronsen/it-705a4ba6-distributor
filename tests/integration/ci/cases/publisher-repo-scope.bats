# A publisher limited to some repos can't publish the others.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  lifecycle__reset
}

@test "a publisher limited to the testbed can't publish the second repo" {
  local repo testbed name id
  repo=$(suite__service2_repo)
  testbed=$(suite__testbed_repo)
  name=$(suite__repo_name "$repo")
  id=$(gh api user -q .id)
  distributor__push_config > /dev/null << EOF
publishers:
  "$id": {username: distributor-it, repos: [$testbed]}
repos:
  - name: $testbed
    allow: [testbed, testbed-quadlet]
  - name: $repo
EOF
  crafted__release "$repo" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: rejected, its pusher may not publish this repo" state__has \
    --arg k "$repo@v1.0.0" --arg r "may not publish $repo" \
    '.[$k].status == "rejected" and (.[$k].reasons | any(contains($r)))'
}
