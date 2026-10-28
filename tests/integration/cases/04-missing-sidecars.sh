# shellcheck shell=bash
# Case 4: a release without sidecars is rejected once, with one issue, and never processed again.

# Drops the crafted release, pass or fail, so its tag can't confuse later tag lookups.
case_cleanup() {
  release_drop "$T" test-empty 2> /dev/null || true
}

case_main() {
  local tag=test-empty
  release_create "$T" "$tag"
  poll_once > /dev/null
  check "$tag: rejected" test "$(release_status "$T" "$tag")" = rejected
  check "$tag: a missing reason per sidecar" state_has --arg k "$T@$tag" \
    '[.[$k].reasons[] | select(startswith("missing "))] | length == 4'
  check "$tag: one issue" test "$(issue_count "Rejected release: $T@$tag" OPEN)" = 1
  local at
  at=$(state_get | jq -r --arg k "$T@$tag" '.[$k].at')
  poll_once > /dev/null
  check "$tag: not processed again" state_has --arg k "$T@$tag" --arg at "$at" '.[$k].at == $at'
  check "$tag: still one issue" test "$(issue_count "Rejected release: $T@$tag")" = 1
}
