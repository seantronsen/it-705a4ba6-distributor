# A poll without ARCHIVE_GPG_KEY fails at its keys job, before discover: nothing is admitted or
# rejected, and nothing is published unsigned.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a poll without an archive key fails" {
  local role=fixture repo distributor run
  repo="$(settings__get ".repos.${role}.remote")"
  distributor="$(settings__get .repos.distributor.remote)"
  crafted__release_create "${role}" v1.0.0 "$(suite__repo_name "${repo}") 1.0.0"
  # lifecycle__reset sets it again.
  gh secret delete ARCHIVE_GPG_KEY -R "${distributor}"
  run="$(poll__dispatch 1)"
  wait__check "keys job failed" github__has_jobs_concluded "${distributor}" "${run}" keys failure
  wait__check "discover skipped" github__has_jobs_concluded "${distributor}" "${run}" discover \
    skipped
  wait__check "v1.0.0: not processed" test "$(state__release_status "${repo}" v1.0.0)" = absent
}
