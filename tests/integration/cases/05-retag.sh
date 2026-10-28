# shellcheck shell=bash
# Case 5: an admitted version published again under a new tag is rejected. Runs while v1.0.1's
# 1-day signing key is valid (ensure_published makes it fresh on a new run).

# Drops the crafted release, pass or fail, so its tag can't confuse later tag lookups.
case_cleanup() {
  release_drop "$T" test-retag 2> /dev/null || true
}

case_main() {
  local tag=test-retag
  ensure_published v1.0.1
  release_copy v1.0.1 "$tag"
  poll_once > /dev/null
  check "$tag: rejected" test "$(release_status "$T" "$tag")" = rejected
  check "$tag: every package already admitted" state_has --arg k "$T@$tag" \
    '.[$k].reasons | length == 6
     and all(endswith("was already admitted; ship a new patch version"))'
  check "$tag: one issue" test "$(issue_count "Rejected release: $T@$tag")" = 1
}
