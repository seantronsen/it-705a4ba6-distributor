# An archive key expiring within 30 days fails every poll before discover and keeps an
# "Archive key expiring" issue open; a fresh key passes and closes it.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/archive.sh"
  source "$BATS_TEST_DIRNAME/../lib/github.sh"
  source "$BATS_TEST_DIRNAME/../lib/issues.sh"
  source "$BATS_TEST_DIRNAME/../lib/keys.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  lifecycle__reset
}

@test "an expiring archive key fails polls until it's replaced" {
  local distributor run
  distributor=$(suite__distributor_repo)
  archive__set_secret "$(archive__new 7d)"
  run=$(poll__run)
  wait__check "keys job failed" github__jobs_concluded "$distributor" "$run" keys failure
  wait__check "discover skipped" github__jobs_concluded "$distributor" "$run" discover skipped
  wait__check "an Archive key expiring issue" \
    test "$(issues__count "Archive key expiring" OPEN)" = 1
  run=$(poll__run)
  wait__check "still one issue" test "$(issues__count "Archive key expiring")" = 1
  keys__set_archive_secret valid
  run=$(poll__run)
  wait__check "keys job passed" github__jobs_concluded "$distributor" "$run" keys success
  wait__check "the issue closed" test "$(issues__count "Archive key expiring" CLOSED)" = 1
}
