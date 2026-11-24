#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Record a run's results.
#
#   record.sh <state|issues|all> <file>...
#
# state: applies each file to $STATE as a delta: admit result.json files upsert their release
# entry; publish and prune delta files patch package entries (status, reason). Run it on freshly
# fetched state so concurrent writers never overwrite each other.
# issues: opens an issue per rejected release and per denied repo key, unless one is already
# open. CI runs state inside the commit retry loop and issues once after it.
#
# Environment: GITHUB_TOKEN, GITHUB_REPOSITORY (required for issues).
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/state.sh"

################################################################################
# Applies the result files to STATE: release entries first, then the package patches that
# refer to them.
# Arguments:
#   <result.json|delta.json>...
################################################################################
apply_deltas_to_state() {
  local state f releases=() patches=()
  state="$(state__json)"
  for f in "$@"; do
    if jq -e .key "${f}" > /dev/null; then releases+=("${f}"); else patches+=("${f}"); fi
  done
  for f in "${releases[@]}" "${patches[@]}"; do
    state="$(base__jq -c --slurpfile d "${f}" \
      'import "state" as state; state::apply_delta($d[0])' <<< "${state}")"
  done

  jq -S . <<< "${state}" > "${STATE}.tmp"
  mv "${STATE}.tmp" "${STATE}"
  log__info "record: updated ${STATE}"
}

################################################################################
# The body of a rejected release's issue.
# Arguments:
#   <result.json>
# Outputs:
#   The body on stdout.
################################################################################
rejection_issue_body() {
  local result="$1" key reasons run
  key="$(jq -r .key "${result}")"
  reasons="$(jq -r '.reasons | map("- \(.)") | join("\n")' "${result}")"
  run="$(jq -r .run "${result}")"
  cat << EOF
Release \`${key}\` was rejected, so none of its packages were published.

${reasons}

Run: ${run}

Fix the problem and publish a new patch release; this release won't be processed again.
EOF
}

################################################################################
# The body of a denied repo key's issue.
# Arguments:
#   <denied packages of one repo and key, as JSON>
# Outputs:
#   The body on stdout.
################################################################################
denial_issue_body() {
  local packages
  packages="$(jq -r 'map("- `\(.filename)` (\(.release))") | join("\n")' <<< "$1")"
  cat << EOF
These packages were admitted with a denied repo key and have been unpublished:

${packages}
EOF
}

################################################################################
# Opens an issue per rejected release, unless one is open, and one per denied repo key and
# wave: a package is denied only once, so a later wave for the same key gets its own issue.
# Arguments:
#   <result.json|delta.json>...
################################################################################
open_issues() {
  local f group key
  for f in "$@"; do
    jq -e '.key and .status == "rejected"' "${f}" > /dev/null || continue
    github__issue_ensure_open "Rejected release: $(jq -r .key "${f}")" rejected-release \
      "$(rejection_issue_body "${f}")"
  done
  while IFS= read -r group; do
    key="$(jq -r '.[0] | "\(.repo) \(.fingerprint)"' <<< "${group}")"
    github__issue_create "Denied repo key: ${key} ($(date -u +%F))" denied-repo-key \
      "$(denial_issue_body "${group}")"
  # The denied packages across the delta files, one group per repo and key.
  done < <(jq -c -s '[.[].denied // [] | .[]] | group_by([.repo, .fingerprint])[]' "$@")
}

################################################################################
# Records the result files: the state, the issues, or both.
# Arguments:
#   <state|issues|all> <result.json|delta.json>...
################################################################################
main() {
  local mode="$1"
  shift
  if [[ "${mode}" == state || "${mode}" == all ]]; then apply_deltas_to_state "$@"; fi
  if [[ "${mode}" == issues || "${mode}" == all ]]; then
    base__env_require GITHUB_TOKEN GITHUB_REPOSITORY
    open_issues "$@"
  fi
}

[[ "$#" -ge 2 ]] || log__fatal "usage: record.sh <state|issues|all> <result.json|delta.json>..."
case "$1" in
  state | issues | all) ;;
  *) log__fatal "unknown mode: $1 (state, issues, or all)" ;;
esac
main "$@"
