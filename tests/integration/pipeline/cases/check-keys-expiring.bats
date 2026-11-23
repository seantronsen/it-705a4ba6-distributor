# An archive key expiring within 30 days fails every poll before discover and keeps an
# "Archive key expiring" issue open; a fresh key passes and closes it.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "an expiring archive key fails polls until it's replaced" {
  local distributor run
  distributor="$(settings__get .repos.distributor.remote)"
  keys__archive_secret_set "$(keys__archive_generate 7d)"
  run="$(poll__run)"
  wait__check "keys job failed" github__has_jobs_concluded "${distributor}" "${run}" keys failure
  wait__check "discover skipped" github__has_jobs_concluded "${distributor}" "${run}" discover \
    skipped
  wait__check "an Archive key expiring issue" \
    test "$(distributor__issue_count "Archive key expiring" OPEN)" = 1
  run="$(poll__run)"
  wait__check "still one issue" test "$(distributor__issue_count "Archive key expiring")" = 1
  keys__archive_secret_set "$(keys__fingerprint archive)"
  run="$(poll__run)"
  wait__check "keys job passed" github__has_jobs_concluded "${distributor}" "${run}" keys success
  wait__check "the issue closed" \
    test "$(distributor__issue_count "Archive key expiring" CLOSED)" = 1
}
