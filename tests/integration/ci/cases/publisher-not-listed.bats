# A release whose tag was pushed by someone not in publishers is rejected.

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

@test "a release pushed by a non-publisher is rejected" {
  local repo name
  repo=$(suite__service2_repo)
  name=$(suite__repo_name "$repo")
  # GitHub user 1 is someone else: the suite's user isn't a publisher.
  distributor__push_config > /dev/null << EOF
publishers:
  "1": {username: mojombo}
repos:
  - name: $(suite__testbed_repo)
    allow: [testbed, testbed-quadlet]
  - name: $repo
EOF
  crafted__release "$repo" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: rejected, its pusher may not publish" state__has \
    --arg k "$repo@v1.0.0" --arg r "may not publish $repo" \
    '.[$k].status == "rejected" and (.[$k].reasons | any(contains($r)))'
}
