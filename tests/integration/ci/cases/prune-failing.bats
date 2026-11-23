# When prune can't sign (an archive key under a passphrase the distributor doesn't have), polls
# keep failing without committing and an issue stays open; once the key is fixed, prune succeeds
# and the issue closes.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a failing prune keeps an issue open until it recovers" {
  local role=fixture repo distributor fpr run before
  repo=$(settings__get ".repos.$role.remote")
  distributor=$(settings__get .repos.distributor.remote)
  fpr=$(keys__fpr fixture)
  crafted__release "$role" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  keys__set_archive_secret locked
  # Denying the key gives prune something to remove.
  run=$(distributor__push_config << EOF
$(distributor__publishers)
repos:
  - name: $(settings__get .repos.service.remote)
    allow: $(settings__get '.repos.service.packages | tojson')
  - name: $repo
    deny:
      - fingerprint: $fpr
        reason: distributor-it
EOF
  )
  wait__check "first poll: prune failed" \
    github__has_jobs_concluded "$distributor" "$run" "prune / prune" failure
  before=$(github__head_sha "$distributor")
  run=$(poll__run)
  wait__check "second poll: prune failed" \
    github__has_jobs_concluded "$distributor" "$run" "prune / prune" failure
  wait__check "no state commit while failing" test "$(github__head_sha "$distributor")" = "$before"
  wait__check "a Prune failing issue" test "$(distributor__issue_count "Prune failing" OPEN)" = 1
  keys__set_archive_secret "$(keys__fpr archive)"
  run=$(poll__run)
  wait__check "third poll: prune succeeded" \
    github__has_jobs_concluded "$distributor" "$run" "prune / prune" success
  wait__check "the Prune failing issue closed" \
    test "$(distributor__issue_count "Prune failing" CLOSED)" = 1
  wait__check "no package still published" state__has_none_published "$repo"
}
