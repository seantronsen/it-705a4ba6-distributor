# A newer patch release prunes the previous one's packages (keep the latest patch per minor).

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a new patch release prunes the previous patch" {
  local role=fixture repo name
  repo=$(settings__get ".repos.$role.remote")
  name=$(suite__repo_name "$repo")
  crafted__release "$role" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  crafted__release "$role" v1.0.1 "$name 1.0.1"
  poll__run > /dev/null
  wait__check "v1.0.1: every package published" state__has --arg k "$repo@v1.0.1" \
    '.[$k].packages | length == 2 and all(.status == "published")'
  wait__check "v1.0.0: every package pruned for retention" state__has \
    --arg k "$repo@v1.0.0" '.[$k].packages | all(.status == "pruned" and .reason == "retention")'
}
