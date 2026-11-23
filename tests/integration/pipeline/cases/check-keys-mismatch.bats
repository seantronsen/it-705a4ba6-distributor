# ARCHIVE_GPG_KEY that isn't keys/archive.asc (a half-finished switch) fails the poll before
# discover and the keyring build: nothing is admitted or rejected.

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

@test "an archive key that isn't keys/archive.asc fails the poll" {
  local role=fixture repo distributor before run
  repo="$(settings__get ".repos.${role}.remote")"
  distributor="$(settings__get .repos.distributor.remote)"
  crafted__release_create "${role}" v1.0.0 "$(suite__repo_name "${repo}") 1.0.0"
  before="$(workflow__latest keyring.yml push)"
  distributor__edit "another archive key" keys__public_write "$(keys__archive_generate 60d)" \
    keys/archive.asc
  run="$(workflow__wait_next keyring.yml "${before}" push)"
  wait__check "the keyring build failed" test "$(github__run_wait "${distributor}" "${run}")" = \
    failure
  run="$(poll__run)"
  wait__check "keys job failed" github__has_jobs_concluded "${distributor}" "${run}" keys failure
  wait__check "discover skipped" github__has_jobs_concluded "${distributor}" "${run}" discover \
    skipped
  wait__check "v1.0.0: not processed" test "$(state__release_status "${repo}" v1.0.0)" = absent
}
