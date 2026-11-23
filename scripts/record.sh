#!/usr/bin/env bash
# Record a run's results.
#
#   record.sh <state|issues|all> <file>...
#
# state: applies each file to $STATE as a delta: admit result.json files upsert their release
# entry; publish and prune delta files patch package entries (status, reason). Run it on freshly
# fetched state so concurrent writers never overwrite each other.
# issues: opens an issue per rejected release and per denied repo key, unless one is already
# open. CI runs state inside the commit retry loop and issues once after it.
source "$(dirname "$0")/lib.sh"

[[ $# -ge 2 ]] || die "usage: record.sh <state|issues|all> <result.json|delta.json>..."
mode=$1
shift
case $mode in state | issues | all) ;; *) die "unknown mode: $mode (state, issues, or all)" ;; esac

update_state() {
  # Release entries first, then the package patches that refer to them.
  local state f releases=() patches=()
  state=$(state_json)
  for f in "$@"; do
    if jq -e .key "$f" > /dev/null; then releases+=("$f"); else patches+=("$f"); fi
  done
  for f in "${releases[@]}" "${patches[@]}"; do
    state=$(jql -c --slurpfile d "$f" 'import "record" as record; record::apply($d[0])' \
      <<< "$state")
  done

  mkdir -p "$(dirname "$STATE")"
  jq -S . <<< "$state" > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  log "record: updated $STATE"
}

file_issues() {
  local f group
  for f in "$@"; do
    jq -e '.key and .status == "rejected"' "$f" > /dev/null || continue
    issue_ensure "Rejected release: $(jq -r .key "$f")" rejected-release \
      "$(jql -r 'import "record" as record; record::rejection_body' "$f")"
  done
  # One issue per denied repo key and wave, across the rpm and deb deltas. A package is denied
  # only once, so a later wave for the same key gets its own issue.
  while IFS= read -r group; do
    issue_create "Denied repo key: $(jq -r '.[0] | "\(.repo) \(.fingerprint)"' <<< "$group") ($(date -u +%F))" \
      denied-repo-key \
      "$(jql -r 'import "record" as record; record::denial_body' <<< "$group")"
  done < <(jql -c -s 'import "record" as record; record::denial_groups' "$@")
}

[[ $mode == state || $mode == all ]] && update_state "$@"
[[ $mode == issues || $mode == all ]] && file_issues "$@"
exit 0
