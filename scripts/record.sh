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
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/state.sh"

[[ $# -ge 2 ]] || log__fatal "usage: record.sh <state|issues|all> <result.json|delta.json>..."
mode=$1
shift
case $mode in
  state | issues | all) ;;
  *) log__fatal "unknown mode: $mode (state, issues, or all)" ;;
esac

################################################################################
# Applies the result files to STATE: release entries first, then the package patches that
# refer to them.
# Arguments:
#   <result.json|delta.json>...
################################################################################
update_state() {
  local state f releases=() patches=()
  state=$(state__json)
  for f in "$@"; do
    if jq -e .key "$f" > /dev/null; then releases+=("$f"); else patches+=("$f"); fi
  done
  for f in "${releases[@]}" "${patches[@]}"; do
    state=$(base__jq -c --slurpfile d "$f" 'import "record" as record; record::apply($d[0])' \
      <<< "$state")
  done

  mkdir -p "$(dirname "$STATE")"
  jq -S . <<< "$state" > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  log__info "record: updated $STATE"
}

################################################################################
# Opens an issue per rejected release, unless one is open, and one per denied repo key and
# wave: a package is denied only once, so a later wave for the same key gets its own issue.
# Arguments:
#   <result.json|delta.json>...
################################################################################
file_issues() {
  local f group key
  for f in "$@"; do
    jq -e '.key and .status == "rejected"' "$f" > /dev/null || continue
    github__ensure_issue "Rejected release: $(jq -r .key "$f")" rejected-release \
      "$(base__jq -r 'import "record" as record; record::rejection_body' "$f")"
  done
  while IFS= read -r group; do
    key=$(jq -r '.[0] | "\(.repo) \(.fingerprint)"' <<< "$group")
    github__create_issue "Denied repo key: $key ($(date -u +%F))" denied-repo-key \
      "$(base__jq -r 'import "record" as record; record::denial_body' <<< "$group")"
  done < <(base__jq -c -s 'import "record" as record; record::denial_groups' "$@")
}

[[ $mode == state || $mode == all ]] && update_state "$@"
[[ $mode == issues || $mode == all ]] && file_issues "$@"
exit 0
