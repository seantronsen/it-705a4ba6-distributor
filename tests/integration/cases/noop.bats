# A poll that finds nothing new skips admission and commits nothing.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  lifecycle__reset
}

@test "a poll with nothing new changes nothing" {
  local repo distributor before run
  repo=$(suite__service2_repo)
  distributor=$(suite__distributor_repo)
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  distributor__poll > /dev/null
  before=$(github__head_sha "$distributor")
  run=$(distributor__poll)
  wait__check "poll succeeded" test "$(github__run_wait "$distributor" "$run")" = success
  wait__check "admit skipped" github__jobs_concluded "$distributor" "$run" admit skipped
  wait__check "no state commit" test "$(github__head_sha "$distributor")" = "$before"
}
