# The keyring workflow builds openchami-keyring 1.0.0 carrying the archive key and publishes it
# like an admitted release. Exports the published repositories to artifacts/keyring.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/keyring.sh"
  source "$BATS_TEST_DIRNAME/../lib/keys.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../lib/workflow.sh"
  lifecycle__reset
}

@test "the keyring workflow publishes openchami-keyring" {
  local run fpr dir
  fpr=$(keys__fpr archive)
  dir="$(suite__artifacts_dir)/keyring"
  run=$(workflow__run keyring.yml)
  wait__check "1.0.0: published, deb and rpm" state__has --arg k openchami-keyring@1.0.0 '
    .[$k].status == "published"
    and (.[$k].packages | length == 2 and all(.status == "published"))'
  wait__check "the rpm signed with the archive key" state__has \
    --arg k openchami-keyring@1.0.0 --arg f "$fpr" \
    '.[$k].packages | map(select(.format == "rpm")) | length == 1 and all(.signed_with == $f)'
  poll__download_published "$run" "$dir"
  keyring__check "$dir" 1.0.0 "$fpr"
}
