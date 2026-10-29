# A newer patch release prunes the previous one's packages (keep the latest patch per minor).

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  lifecycle__reset
}

@test "a new patch release prunes the previous patch" {
  local repo name
  repo=$(suite__service2_repo)
  name=$(suite__repo_name "$repo")
  crafted__release "$repo" v1.0.0 "$name 1.0.0"
  distributor__poll > /dev/null
  crafted__release "$repo" v1.0.1 "$name 1.0.1"
  distributor__poll > /dev/null
  wait__check "v1.0.1: every package published" distributor__state_has --arg k "$repo@v1.0.1" \
    '.[$k].packages | length == 2 and all(.status == "published")'
  wait__check "v1.0.0: every package pruned for retention" distributor__state_has \
    --arg k "$repo@v1.0.0" '.[$k].packages | all(.status == "pruned" and .reason == "retention")'
}
