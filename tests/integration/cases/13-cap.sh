# shellcheck shell=bash
# Case 13: discover admits at most MAX_RELEASES per poll, oldest first, and leaves the rest for
# the next poll. The distributor's cap of 256 is lowered to 3 (in the throwaway copy only) so
# four releases test it.

TAGS=(case13-1 case13-2 case13-3 case13-4)

set_cap() { # <from> <to>
  clone_main "$D" cap
  sed -i "s/^MAX_RELEASES=$1\$/MAX_RELEASES=$2/" "$WORK/cap/scripts/discover.sh"
  grep -q "^MAX_RELEASES=$2\$" "$WORK/cap/scripts/discover.sh" || die "can't set MAX_RELEASES"
  commit_all "$WORK/cap" "it: MAX_RELEASES=$2"
  push_main "$WORK/cap"
}

case_cleanup() {
  local tag
  set_cap 3 256 2> /dev/null || true
  for tag in "${TAGS[@]}"; do release_drop "$S" "$tag" 2> /dev/null || true; done
}

case_main() {
  local tag
  set_cap 256 3
  # Empty releases are enough: discover orders by publish time; admit just rejects them.
  for tag in "${TAGS[@]}"; do
    release_create "$S" "$tag"
    sleep 2
  done
  poll_once > /dev/null
  for tag in case13-1 case13-2 case13-3; do
    check "first poll: $tag processed" test "$(release_status "$S" "$tag")" = rejected
  done
  check "first poll: case13-4 left for later" test "$(release_status "$S" case13-4)" = absent
  poll_once > /dev/null
  check "second poll: case13-4 processed" test "$(release_status "$S" case13-4)" = rejected
}
