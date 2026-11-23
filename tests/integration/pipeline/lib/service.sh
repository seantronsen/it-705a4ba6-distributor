# shellcheck shell=bash
# The throwaway service repo: making real releases through its release workflow. Seeding it is
# in lifecycle.sh.

[[ -n "${_IT_SERVICE_SH:-}" ]] && return 0
_IT_SERVICE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/suite/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/github.sh"

################################################################################
# Tags main and waits for the release workflow to publish the release.
# Arguments:
#   Tag.
# Returns:
#   0 when published, 1 when the build failed or timed out.
################################################################################
service__release_create() {
  local repo dir
  repo="$(settings__get .repos.service.remote)"
  dir="$(mktemp -d)"
  git__clone "${repo}" "${dir}/repo" || return 1
  # Tests start without tags, so this is the only one on its commit (GoReleaser builds the
  # highest tag on HEAD).
  git__push_tag "${dir}/repo" "${repo}" "$1" || return 1
  log__info "tagged ${repo} $1"
  wait__until "${repo} $1 released" service__release_state "$1" "${SECONDS}"
}

################################################################################
# Where a tag's release build stands.
# Arguments:
#   Tag, $SECONDS when it was pushed.
# Returns:
#   0 published, 1 not yet, 2 its release run finished without publishing it or never started.
################################################################################
service__release_state() {
  local repo run id status conclusion
  repo="$(settings__get .repos.service.remote)"
  service__is_published "$1" && return 0
  run="$(gh api "repos/${repo}/actions/runs?event=push&branch=$1" \
    -q '[.workflow_runs[] | select(.path == ".github/workflows/release.yml")][0] // empty
      | "\(.id) \(.status) \(.conclusion // "")"')"
  read -r id status conclusion <<< "${run}"
  # A release.yml GitHub can't parse (e.g. a reusable workflow pinned to a commit that's gone)
  # never starts a run.
  if [[ -z "${id}" ]] && ((SECONDS - $2 > 300)); then
    log__error "no release run for $1 after 5 minutes: is release.yml valid? https://github.com/${repo}/actions"
    return 2
  fi
  [[ "${status}" == completed ]] || return 1
  # The release is published within the run; this rereads it in case the first read lagged.
  service__is_published "$1" && return 0
  log__error "release run for $1: ${conclusion:-none}, release not published"
  github__run_failures_log "${repo}" "${id}"
  return 2
}

################################################################################
# Whether a tag's release is published (not a draft).
# Arguments:
#   Tag.
# Returns:
#   0 when published, 1 otherwise.
################################################################################
service__is_published() {
  [[ $(gh release view "$1" -R "$(settings__get .repos.service.remote)" --json isDraft -q .isDraft \
    2> /dev/null) == false ]]
}
