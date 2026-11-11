# Committing keys/ (rotation step 2: archive.asc plus archive-next.asc) triggers the keyring
# workflow, which publishes a keyring carrying both keys, signed with the current one.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/archive.sh"
  source "$BATS_TEST_DIRNAME/../lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../lib/edit.sh"
  source "$BATS_TEST_DIRNAME/../lib/github.sh"
  source "$BATS_TEST_DIRNAME/../lib/keyring.sh"
  source "$BATS_TEST_DIRNAME/../lib/keys.sh"
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

# keys/ for a rotation: the current key and the next.
write_keys() {
  archive__write_public "$1" keys/archive.asc && archive__write_public "$2" keys/archive-next.asc
}

@test "a keys/ change publishes a keyring carrying the current and next keys" {
  local current next before run dir
  current=$(keys__fpr archive)
  next=$(archive__new 60d)
  dir="$(suite__artifacts_dir)/keyring-rotation"
  before=$(workflow__latest keyring.yml push)
  edit__distributor "next archive key" write_keys "$current" "$next"
  run=$(workflow__wait_next keyring.yml "$before" push)
  wait__check "the keyring run succeeded" \
    test "$(github__run_wait "$(suite__distributor_repo)" "$run")" = success
  wait__check "1.0.0: rpm signed with the current key" state__has \
    --arg k openchami-keyring@1.0.0 --arg f "$current" \
    '.[$k].packages | map(select(.format == "rpm")) | length == 1 and all(.signed_with == $f)'
  poll__download_published "$run" "$dir"
  keyring__check "$dir" 1.0.0 "$current" "$next"
}
