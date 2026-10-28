# shellcheck shell=bash
# Case 6: a release whose checksums.txt is signed by a key nothing certified is rejected.

# Drops the crafted release, pass or fail, so its tag can't confuse later tag lookups.
case_cleanup() {
  release_drop "$T" test-badsig 2> /dev/null || true
}

case_main() {
  local tag=test-badsig
  ensure_published v1.0.1
  release_copy v1.0.1 "$tag" badsig
  poll_once > /dev/null
  check "$tag: rejected" test "$(release_status "$T" "$tag")" = rejected
  check "$tag: trust chain reason" state_has --arg k "$T@$tag" \
    --arg r "trust chain or checksums.txt signature didn't verify (see the run log)" \
    '.[$k].reasons == [$r]'
  check "$tag: one issue" test "$(issue_count "Rejected release: $T@$tag")" = 1
}
