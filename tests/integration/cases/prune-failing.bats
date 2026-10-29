# When prune can't sign (a broken archive key), polls keep failing without committing and an
# issue stays open; once the key is fixed, prune succeeds and the issue closes.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  lifecycle__reset
}

@test "a failing prune keeps an issue open until it recovers" {
  local repo distributor fpr run before
  repo=$(suite__service2_repo)
  distributor=$(suite__distributor_repo)
  fpr=$(keys__fpr service2)
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  distributor__poll > /dev/null
  keys__set_archive_secret garbage
  # Denying the key gives prune something to remove.
  run=$(distributor__push_config << EOF
repos:
  - name: $(suite__testbed_repo)
    allow: [testbed, testbed-quadlet]
  - name: $repo
    deny:
      - fingerprint: $fpr
        reason: distributor-it
EOF
  )
  wait__check "first poll: prune failed" github__jobs_concluded "$distributor" "$run" prune failure
  before=$(github__head_sha "$distributor")
  run=$(distributor__poll)
  wait__check "second poll: prune failed" github__jobs_concluded "$distributor" "$run" prune failure
  wait__check "no state commit while failing" test "$(github__head_sha "$distributor")" = "$before"
  wait__check "a Prune failing issue" test "$(distributor__issue_count "Prune failing" OPEN)" = 1
  keys__set_archive_secret valid
  run=$(distributor__poll)
  wait__check "third poll: prune succeeded" \
    github__jobs_concluded "$distributor" "$run" prune success
  wait__check "the Prune failing issue closed" \
    test "$(distributor__issue_count "Prune failing" CLOSED)" = 1
  wait__check "no package still published" distributor__none_published "$repo"
}
