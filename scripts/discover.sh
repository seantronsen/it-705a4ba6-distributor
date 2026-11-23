#!/usr/bin/env bash
# Discover: list releases not yet in state.
# Prints a JSON matrix of {repo, tag}: the oldest new releases first, at most the config's
# max-releases; the rest wait for the next polls.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/state.sh"

cfg=$(config__get .repos)
max=$(config__get '.["max-releases"]')

# State goes to jq on stdin: it outgrows the command-line argument limit.
new=$(mktemp)
while IFS= read -r repo; do
  releases=$(github__releases "$repo")
  state__json | base__jq -c --arg repo "$repo" --argjson rel "$releases" \
    'import "discover" as discover; discover::new($repo; $rel)' >> "$new"
done < <(jq -r 'keys[]' <<< "$cfg")

log__info "discover: $(wc -l < "$new") new release(s), admitting at most $max"
jq -s -c --argjson max "$max" 'sort_by(.published_at) | .[:$max] | map({repo, tag})' "$new"
