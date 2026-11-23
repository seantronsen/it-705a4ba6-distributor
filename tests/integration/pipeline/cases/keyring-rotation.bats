# Committing keys/ (rotation step 2: archive.asc plus archive-next.asc) triggers the keyring
# workflow, which publishes a keyring carrying both keys, signed with the current one.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

# Reverting keys/ (the reset's force push) triggers the keyring workflow, which commits state
# after the reset; a second reset undoes that, so the next test starts clean.
teardown() {
  local valid=true
  # Before the reset, which puts the seed state back.
  lifecycle__check_state || valid=false
  lifecycle__reset_distributor && lifecycle__reset_distributor
  ${valid}
}

# keys/ for a rotation: the current key and the next.
write_keys() {
  keys__public_write "$1" keys/archive.asc && keys__public_write "$2" keys/archive-next.asc
}

@test "a keys/ change publishes a keyring carrying the current and next keys" {
  local current next before run dir
  current="$(keys__fingerprint archive)"
  next="$(keys__archive_generate 60d)"
  dir="$(settings__get .run.artifacts_dir)/keyring-rotation"
  before="$(workflow__latest keyring.yml push)"
  distributor__edit "next archive key" write_keys "${current}" "${next}"
  run="$(workflow__wait_next keyring.yml "${before}" push)"
  wait__check "the keyring run succeeded" \
    test "$(github__run_wait "$(settings__get .repos.distributor.remote)" "${run}")" = success
  wait__check "1.0.0: rpm signed with the current key" state__has \
    --arg k openchami-keyring@1.0.0 --arg f "${current}" \
    '.[$k].packages | map(select(.format == "rpm")) | length == 1 and all(.signed_with == $f)'
  s3__release_download openchami-keyring 1.0.0 "${dir}"
  keyring__check "${dir}" 1.0.0 "${current}" "${next}"
}
