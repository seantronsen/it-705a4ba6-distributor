# shellcheck shell=bash
# Case 14: two polls dispatched together run one after the other (concurrency group "poll"); the
# second reads the state the first committed and finds nothing new.

case_main() {
  local tag=v1.2.0 a b
  [[ $(release_status "$T" "$tag") == absent ]] || skip_case "$tag was already admitted"
  gh release view "$tag" -R "$T" > /dev/null 2>&1 || tag_release "$tag"
  wait_for "$T $tag released" release_published "$T" "$tag" || exit 2
  NEW_AFTER=$(latest_poll)
  gh workflow run poll.yml -R "$D" --ref main > /dev/null
  gh workflow run poll.yml -R "$D" --ref main > /dev/null
  wait_for "both polls start" two_dispatched || exit 2
  read -r a b <<< "$NEW_RUNS"
  printf '%s\n%s\n' "$a" "$b" >> "$RUN/results/$CASE.runs"
  run_wait "$a" > /dev/null
  run_wait "$b" > /dev/null
  check "first poll admitted $tag" job_all "$a" admit success
  check "second poll found nothing new" job_all "$b" admit skipped
  check "$tag: published" test "$(release_status "$T" "$tag")" = published
  check "state committed by the first poll" committed_by "$a"
  check "no state commit by the second" not_committed_by "$b"
}

# State commits end with their run's URL.
committed_by() { # <run id>
  gh api "repos/$D/commits?per_page=20" -q '.[].commit.message' | grep -q "/runs/$1\$"
}

not_committed_by() { # <run id>
  ! committed_by "$1"
}

two_dispatched() { # sets NEW_RUNS to the two oldest dispatched runs after NEW_AFTER
  NEW_RUNS=$(gh api "repos/$D/actions/workflows/poll.yml/runs?event=workflow_dispatch&per_page=20" \
    -q "[.workflow_runs[] | select(.id > $NEW_AFTER) | .id] | sort | .[:2] | join(\" \")")
  [[ $(wc -w <<< "$NEW_RUNS") -eq 2 ]]
}
