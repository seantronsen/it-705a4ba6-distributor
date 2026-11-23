# shellcheck shell=bash
# The GitHub API, through gh (GITHUB_TOKEN): releases, assets, a tag's push runs, and issues.

[[ -n ${_LIB_GITHUB_SH:-} ]] && return 0
_LIB_GITHUB_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

################################################################################
# The URL of the running workflow run.
# Globals:
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID
# Outputs:
#   The URL on stdout.
################################################################################
github__current_run_url() {
  echo "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
}

################################################################################
# A repo's releases.
# Arguments:
#   <owner/repo>
# Outputs:
#   A JSON array of {tag_name, draft, prerelease, published_at} on stdout.
################################################################################
github__release_list() {
  gh api --paginate "repos/$1/releases?per_page=100" \
    --jq '.[] | {tag_name, draft, prerelease, published_at}' | jq -s -c .
}

################################################################################
# A release's assets.
# Arguments:
#   <owner/repo> <tag>
# Outputs:
#   A JSON array of {name, id} on stdout.
################################################################################
github__release_asset_list() {
  gh api "repos/$1/releases/tags/$(base__uri_encode "$2")" | jq -c '[.assets[] | {name, id}]'
}

################################################################################
# Who pushed and who ran a tag's push runs: each run's actor (role "pushed") and the triggering
# actor of each of its attempts (role "ran"). A re-run replaces the run's triggering actor, so
# earlier attempts are read one by one. Runs match by head_branch, so pushes to a branch with
# the tag's name count too.
# Arguments:
#   <owner/repo> <tag>
# Outputs:
#   A JSON array of {run, attempt, role, login, id, type} on stdout.
# Returns:
#   1 on any API failure (set -e is off when it's called from a condition), so a failed call is
#   an infrastructure error, never an empty list.
################################################################################
github__tag_push_actor_list() {
  local repo=$1 tag=$2 runs reruns run count n
  runs=$(gh api --paginate \
      "repos/$repo/actions/runs?event=push&branch=$(base__uri_encode "$tag")&per_page=100" \
      --jq '.workflow_runs[]' \
    | jq -c --arg t "$tag" 'select(.event == "push" and .head_branch == $t)
        | {run: .id, attempt: .run_attempt, actor, triggering_actor}') || return 1
  reruns=$(jq -r 'select(.attempt > 1) | "\(.run) \(.attempt)"' <<< "$runs") || return 1
  {
    jq -c '{run, attempt} as $r
      | (.actor | {login, id, type} + $r + {role: "pushed"}),
        (.triggering_actor | {login, id, type} + $r + {role: "ran"})' <<< "$runs" || return 1
    while read -r run count; do
      for ((n = 1; n < count; n++)); do
        gh api "repos/$repo/actions/runs/$run/attempts/$n" \
          --jq '{run: .id, attempt: .run_attempt, role: "ran"}
            + (.triggering_actor | {login, id, type})' \
          || return 1
      done
    done <<< "$reruns"
  } | jq -s -c .
}

################################################################################
# Downloads a release asset.
# Arguments:
#   <owner/repo> <asset id> <dest>
################################################################################
github__release_asset_download() {
  gh api -H 'Accept: application/octet-stream' "repos/$1/releases/assets/$2" > "$3"
}

################################################################################
# The open issue with a title and label in this repo.
# Globals:
#   GITHUB_REPOSITORY
# Arguments:
#   <title> <label>
# Outputs:
#   Its number on stdout, or nothing.
################################################################################
github__issue_find_open() {
  gh api \
    "repos/$GITHUB_REPOSITORY/issues?state=open&labels=$(base__uri_encode "$2")&per_page=100" \
    | jq -r --arg t "$1" '[.[] | select(.title == $t)][0].number // empty'
}

################################################################################
# Opens an issue in this repo, unless an open one with its title and label exists.
# Globals:
#   GITHUB_REPOSITORY
# Arguments:
#   <title> <label> <body>
################################################################################
github__issue_ensure_open() {
  local number
  number=$(github__issue_find_open "$1" "$2")
  if [[ -n $number ]]; then
    log__info "issue #$number already open: $1"
    return
  fi
  github__issue_create "$1" "$2" "$3"
}

################################################################################
# Comments on and closes the open issue with a title and label in this repo, if any.
# Globals:
#   GITHUB_REPOSITORY
# Arguments:
#   <title> <label> <comment>
################################################################################
github__issue_close() {
  local number
  number=$(github__issue_find_open "$1" "$2")
  [[ -n $number ]] || return 0
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$number/comments" -f body="$3" > /dev/null
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/$number" -f state=closed > /dev/null
}

################################################################################
# Opens an issue in this repo.
# Globals:
#   GITHUB_REPOSITORY
# Arguments:
#   <title> <label> <body>
################################################################################
github__issue_create() {
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues" -f title="$1" -f body="$3" -f "labels[]=$2" \
    > /dev/null
}
