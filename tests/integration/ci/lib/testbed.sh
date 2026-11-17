# shellcheck shell=bash
# The throwaway testbed: seeding it and making real releases through its release workflow.

[[ -n ${_IT_TESTBED_SH:-} ]] && return 0
_IT_TESTBED_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

################################################################################
# Pushes the local testbed checkout (a copy at /src/testbed) to the throwaway repo, with its
# images renamed into the owner's GHCR namespace, the marker, and the tag workflow.
# Returns:
#   0, or 1 when the push failed.
################################################################################
testbed__seed() {
  local repo owner image dir
  repo=$(suite__testbed_repo)
  owner=${repo%%/*}
  image=ghcr.io/${owner,,}/$(suite__repo_name "$repo")
  dir=$(mktemp -d)
  if ! git clone --quiet /src/testbed "$dir/repo"; then
    log__error "can't clone /src/testbed"
    return 1
  fi
  if ! sed -i "s|ghcr.io/openchami/github-actions-testbed|$image|" \
    "$dir/repo/.goreleaser.yaml"; then
    log__error "can't rename the images"
    return 1
  fi
  echo distributor-it > "$dir/repo/$(suite__marker)"
  git__add_tag_workflow "$dir/repo"
  git__commit "$dir/repo" "it: seed" || return 1
  git__push_main "$dir/repo" "$repo" --force
}

################################################################################
# Tags main and waits for the release workflow to publish the release. Tests start without
# tags, so the tag is the only one on its commit (GoReleaser builds the highest tag on HEAD).
# Arguments:
#   Tag.
# Returns:
#   0 when published, 1 when the build failed or timed out.
################################################################################
testbed__release() {
  local repo dir
  repo=$(suite__testbed_repo)
  dir=$(mktemp -d)
  git__clone "$repo" "$dir/repo" || return 1
  git__push_tag "$dir/repo" "$repo" "$1" || return 1
  log__info "tagged $repo $1"
  wait__until "$repo $1 released" testbed__release_state "$1" "$SECONDS"
}

################################################################################
# Where a tag's release build stands. A release.yml GitHub can't parse (e.g. a reusable workflow
# pinned to a commit that's gone) never starts a run for the tag.
# Arguments:
#   Tag, $SECONDS when it was pushed.
# Returns:
#   0 published, 1 not yet, 2 its release run finished without publishing it or never started.
################################################################################
testbed__release_state() {
  local repo run id status conclusion
  repo=$(suite__testbed_repo)
  testbed__published "$1" && return 0
  run=$(gh api "repos/$repo/actions/runs?event=push&branch=$1" \
    -q '[.workflow_runs[] | select(.path == ".github/workflows/release.yml")][0] // empty
      | "\(.id) \(.status) \(.conclusion // "")"')
  read -r id status conclusion <<< "$run"
  if [[ -z $id ]] && ((SECONDS - $2 > 300)); then
    log__error "no release run for $1 after 5 minutes: is release.yml valid? https://github.com/$repo/actions"
    return 2
  fi
  [[ $status == completed ]] || return 1
  # The release is published within the run; this rereads it in case the first read lagged.
  testbed__published "$1" && return 0
  log__error "release run for $1: ${conclusion:-none}, release not published"
  github__log_failed "$repo" "$id"
  return 2
}

################################################################################
# Whether a tag's release is published (not a draft).
# Arguments:
#   Tag.
# Returns:
#   0 when published, 1 otherwise.
################################################################################
testbed__published() {
  [[ $(gh release view "$1" -R "$(suite__testbed_repo)" --json isDraft -q .isDraft \
    2> /dev/null) == false ]]
}
