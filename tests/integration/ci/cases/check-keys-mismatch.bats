# ARCHIVE_GPG_KEY that isn't keys/archive.asc (a half-finished switch) fails the poll before
# discover and the keyring build: nothing is admitted or rejected.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/archive.sh"
  source "$BATS_TEST_DIRNAME/../lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../lib/edit.sh"
  source "$BATS_TEST_DIRNAME/../lib/github.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../lib/workflow.sh"
  lifecycle__reset
}

# Reverting keys/ (the reset's force push) triggers the keyring workflow, which commits state
# after the reset; a second reset undoes that, so the next test starts clean.
teardown() {
  distributor__reset && distributor__reset
}

@test "an archive key that isn't keys/archive.asc fails the poll" {
  local repo distributor before run
  repo=$(suite__service2_repo)
  distributor=$(suite__distributor_repo)
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  before=$(workflow__latest keyring.yml push)
  edit__distributor "another archive key" archive__write_public "$(archive__new 60d)" \
    keys/archive.asc
  run=$(workflow__wait_next keyring.yml "$before" push)
  wait__check "the keyring build failed" test "$(github__run_wait "$distributor" "$run")" = failure
  run=$(poll__run)
  wait__check "keys job failed" github__jobs_concluded "$distributor" "$run" keys failure
  wait__check "discover skipped" github__jobs_concluded "$distributor" "$run" discover skipped
  wait__check "v1.0.0: not processed" test "$(state__release_status "$repo" v1.0.0)" = absent
}
