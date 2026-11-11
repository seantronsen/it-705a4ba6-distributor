# keys/archive-next.asc committed 30+ days ago opens an "Archive key switch due" issue without
# failing the poll; removing it (the switch is done) closes the issue.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/archive.sh"
  source "$BATS_TEST_DIRNAME/../lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../lib/edit.sh"
  source "$BATS_TEST_DIRNAME/../lib/github.sh"
  source "$BATS_TEST_DIRNAME/../lib/issues.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  lifecycle__reset
}

# Reverting keys/ (the reset's force push) triggers the keyring workflow, which commits state
# after the reset; a second reset undoes that, so the next test starts clean.
teardown() {
  distributor__reset && distributor__reset
}

@test "an old archive-next.asc opens a switch due issue until it's removed" {
  local distributor run
  distributor=$(suite__distributor_repo)
  # check-keys dates the file by its commit's committer date.
  GIT_COMMITTER_DATE=$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%SZ) \
    edit__distributor "next archive key, 40 days ago" \
    archive__write_public "$(archive__new 60d)" keys/archive-next.asc
  run=$(poll__run)
  wait__check "keys job passed" github__jobs_concluded "$distributor" "$run" keys success
  wait__check "an Archive key switch due issue" \
    test "$(issues__count "Archive key switch due" OPEN)" = 1
  edit__distributor "switch done" rm keys/archive-next.asc
  run=$(poll__run)
  wait__check "keys job passed" github__jobs_concluded "$distributor" "$run" keys success
  wait__check "the issue closed" test "$(issues__count "Archive key switch due" CLOSED)" = 1
}
