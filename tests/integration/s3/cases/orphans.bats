# Package files on the bucket that state doesn't list (orphans, here from a state reset) are
# deleted by the next prune.

setup() {
  source "$BATS_TEST_DIRNAME/../../ci/lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/state.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../lib/s3.sh"
  lifecycle__reset
}

@test "orphaned package files are deleted from the bucket" {
  local repo keys key
  repo=$(suite__service2_repo)
  s3__use > /dev/null
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  keys=$(s3__release_keys "$repo" v1.0.0)
  for key in $keys; do wait__check "$key: on the bucket" s3__exists "$key"; done
  # Back to empty state (and the dir target); then the bucket again, whose poll prunes.
  distributor__reset
  s3__use > /dev/null
  for key in $keys; do wait__check "$key: gone" s3__gone "$key"; done
}
