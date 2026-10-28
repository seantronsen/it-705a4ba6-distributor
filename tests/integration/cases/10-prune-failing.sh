# shellcheck shell=bash
# Case 10: prune failing in two polls in a row opens "Prune failing"; the next good prune closes
# it. Prune fails here because the archive key is garbage while it has work: denying everything
# the testbed's key admitted (case 7's change).

prune_issue() { # <OPEN|CLOSED>
  test "$(issue_count "Prune failing" "$1")" = 1
}

restore_key() {
  gpg --armor --export-secret-keys "$ARCHIVE_FPR" | gh secret set ARCHIVE_GPG_KEY -R "$D"
}

# The real key goes back pass or fail; later cases need it.
case_cleanup() {
  restore_key
}

case_main() {
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  local before run
  ensure_published v1.1.0
  ! testbed_none_published || skip_case "nothing published left for prune to remove"
  printf 'garbage' | gh secret set ARCHIVE_GPG_KEY -R "$D"
  config_push "$(deny_all_spec)"
  [[ -n $POLL_RUN ]] || skip_case "the testbed's key was already denied entirely"
  before=$(head_sha "$D")
  check "first poll: prune failed" job_all "$POLL_RUN" "prune / prune" failure
  run=$(poll_once)
  check "second poll: prune failed" job_all "$run" "prune / prune" failure
  check "no state commit while failing" test "$(head_sha "$D")" = "$before"
  check "a Prune failing issue" prune_issue OPEN

  restore_key
  run=$(poll_once)
  check "third poll: prune succeeded" job_all "$run" "prune / prune" success
  check "the Prune failing issue closed" prune_issue CLOSED
  check "no testbed package still published" testbed_none_published
}
