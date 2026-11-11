# A release whose tag has no push run (the release created it) is rejected: its publisher can't
# be checked.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  lifecycle__reset
}

@test "a release without a push run is rejected" {
  local repo
  repo=$(suite__service2_repo)
  # The tag workflow skips no-run-* tags, so no run exists even if GitHub counts the release
  # creating the tag as a push.
  crafted__release "$repo" no-run-1 --no-push "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  wait__check "no-run-1: rejected, no push run" state__has --arg k "$repo@no-run-1" '
    .[$k].status == "rejected" and (.[$k].reasons | any(startswith("no push run found")))'
}
