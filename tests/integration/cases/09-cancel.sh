# shellcheck shell=bash
# Case 9: a poll cancelled before record leaves no state change; the next poll admits the
# release as usual.

# Cancels the run once admit or publish is running; aborts the wait if record already started.
cancel_mid_run() { # <run id>
  local jobs
  jobs=$(gh api "repos/$D/actions/runs/$1/jobs?per_page=100" -q '.jobs[] | "\(.name)\t\(.status)"')
  grep -q $'^record[^\t]*\t\(in_progress\|completed\)' <<< "$jobs" && return 3
  grep -q $'^\(admit\|publish\)[^\t]*\tin_progress' <<< "$jobs" || return 1
  gh run cancel "$1" -R "$D" > /dev/null
}

case_main() {
  local tag=v1.1.0 before run
  [[ $(release_status "$T" "$tag") == absent ]] || skip_case "$tag was already admitted"
  gh release view "$tag" -R "$T" > /dev/null 2>&1 || tag_release "$tag"
  wait_for "$T $tag released" release_published "$T" "$tag" || exit 2
  before=$(head_sha "$D")
  run=$(dispatch_poll)
  wait_for "admit or publish running in $run, then cancel" cancel_mid_run "$run" || exit 2
  check "run cancelled" test "$(run_wait "$run")" = cancelled
  check "no state commit" test "$(head_sha "$D")" = "$before"
  check "$tag: not in state" test "$(release_status "$T" "$tag")" = absent
  poll_once > /dev/null
  check "$tag: published by the next poll" test "$(release_status "$T" "$tag")" = published
}
