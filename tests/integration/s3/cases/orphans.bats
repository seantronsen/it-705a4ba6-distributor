# Package files on the bucket that state doesn't list (orphans, here from a state reset) are
# deleted by the next prune.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "orphaned package files are deleted from the bucket" {
  local role=fixture repo keys key
  repo=$(settings__get ".repos.$role.remote")
  s3__use > /dev/null
  crafted__release "$role" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  keys=$(s3__release_keys "$repo" v1.0.0)
  for key in $keys; do wait__check "$key: on the bucket" s3__has_object "$key"; done
  # Back to empty state (and the dir target), without the release to admit again; then the
  # bucket again, whose poll prunes.
  github__wipe "$repo"
  lifecycle__reset_distributor
  s3__use > /dev/null
  for key in $keys; do wait__check "$key: gone" s3__is_gone "$key"; done
}
