#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Discover: list releases not yet in state.
# Prints a JSON matrix of {repo, tag}: the oldest new releases first, at most the config's
# max_releases; the rest wait for the next polls.
#
# Environment: GITHUB_TOKEN.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/state.sh"

################################################################################
# Lists each configured repo's releases not yet in state, oldest first, capped at max_releases.
# State goes to jq on stdin: it outgrows the command-line argument limit.
# Outputs:
#   The matrix as JSON on stdout.
################################################################################
main() {
  local max new repo releases
  base__env_require GITHUB_TOKEN
  max="$(config__get .max_releases)"
  new="$(mktemp)"
  while IFS= read -r repo; do
    releases="$(github__release_list "${repo}")"
    # Published, non-prerelease releases that state has no entry for.
    state__json | jq -c --arg repo "${repo}" --argjson rel "${releases}" '. as $state
      | $rel[] | select((.draft or .prerelease) | not)
      | {repo: $repo, tag: .tag_name, published_at}
      | select($state["\(.repo)@\(.tag)"] == null)' >> "${new}"
  done < <(config__get .repos | jq -r 'keys[]')
  log__info "discover: $(wc -l < "${new}") new release(s), admitting at most ${max}"
  jq -s -c --argjson max "${max}" 'sort_by(.published_at) | .[:$max] | map({repo, tag})' "${new}"
}

main "$@"
