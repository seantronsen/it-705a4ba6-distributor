# The keyring workflow builds openchami-keyring 1.0.0 carrying the archive key and publishes it
# like an admitted release. Exports its packages to artifacts/keyring.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "the keyring workflow publishes openchami-keyring" {
  local fpr dir
  fpr=$(keys__fpr archive)
  dir="$(settings__get .run.artifacts_dir)/keyring"
  workflow__run keyring.yml > /dev/null
  wait__check "1.0.0: published, deb and rpm" state__has --arg k openchami-keyring@1.0.0 '
    .[$k].status == "published"
    and (.[$k].packages | length == 2 and all(.status == "published"))'
  wait__check "the rpm signed with the archive key" state__has \
    --arg k openchami-keyring@1.0.0 --arg f "$fpr" \
    '.[$k].packages | map(select(.format == "rpm")) | length == 1 and all(.signed_with == $f)'
  s3__download_release openchami-keyring 1.0.0 "$dir"
  keyring__check "$dir" 1.0.0 "$fpr"
}
