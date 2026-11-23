# keys/archive-next.asc committed 30+ days ago opens an "Archive key switch due" issue without
# failing the poll; removing it (the switch is done) closes the issue.

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

@test "an old archive-next.asc opens a switch due issue until it's removed" {
  local distributor run
  distributor="$(settings__get .repos.distributor.remote)"
  # check-keys dates the file by its commit's committer date.
  GIT_COMMITTER_DATE="$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
    distributor__edit "next archive key, 40 days ago" \
    keys__public_write "$(keys__archive_generate 60d)" keys/archive-next.asc
  run="$(poll__run)"
  wait__check "keys job passed" github__has_jobs_concluded "${distributor}" "${run}" keys success
  wait__check "an Archive key switch due issue" \
    test "$(distributor__issue_count "Archive key switch due" OPEN)" = 1
  distributor__edit "switch done" rm keys/archive-next.asc
  run="$(poll__run)"
  wait__check "keys job passed" github__has_jobs_concluded "${distributor}" "${run}" keys success
  wait__check "the issue closed" \
    test "$(distributor__issue_count "Archive key switch due" CLOSED)" = 1
}
