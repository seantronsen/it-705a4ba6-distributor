# shellcheck shell=bash
# Case 3: a prerelease (GoReleaser marks -rc tags) is ignored: no state entry, no issue.

case_main() {
  local tag=v9.0.0-rc1
  gh release view "$tag" -R "$T" > /dev/null 2>&1 || tag_release "$tag"
  wait_for "$T $tag released" release_published "$T" "$tag" || exit 2
  check "$tag is a prerelease" \
    test "$(gh release view "$tag" -R "$T" --json isPrerelease -q .isPrerelease)" = true
  poll_once > /dev/null
  check "$tag: no state entry" test "$(release_status "$T" "$tag")" = absent
  check "$tag: no issue" test "$(issue_count "Rejected release: $T@$tag")" = 0
}
