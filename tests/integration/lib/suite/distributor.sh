# shellcheck shell=bash
# The throwaway distributor repo: its config, edits to it, and the issues it opens. Seeding and
# resetting it are in lifecycle.sh.

[[ -n ${_IT_DISTRIBUTOR_SH:-} ]] && return 0
_IT_DISTRIBUTOR_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../github.sh"
source "$(dirname "${BASH_SOURCE[0]}")/poll.sh"

################################################################################
# The publishers block: the gh user, who also pushes the tags (over the SSH agent).
# Outputs:
#   config/repos.yaml lines on stdout.
################################################################################
distributor__config_publishers() {
  gh api user -q '"publishers:\n  \"\(.id)\": {username: \(.login)}"'
}

################################################################################
# The settings besides publishers and repos: the test bucket as the target, and the live
# config's values for the rest.
# Outputs:
#   config/repos.yaml lines on stdout.
################################################################################
distributor__config_settings() {
  cat << EOF
target:
  s3:
    bucket: $(settings__get .s3.bucket)
    region: $(settings__get .s3.region)
    metadata-max-age: $(settings__get .s3.metadata_max_age)
architectures:
  rpm: [x86_64, aarch64, noarch]
  deb: [amd64, arm64, all]
max-releases: 256
archive-key:
  warn-days: 30
EOF
}

################################################################################
# The default config: publishing to the test bucket, the gh user may publish, the service repo
# is allowed its packages, the fixture repo nothing extra.
# Outputs:
#   config/repos.yaml content on stdout.
################################################################################
distributor__config_default() {
  cat << EOF
$(distributor__config_settings)
$(distributor__config_publishers)
repos:
  $(settings__get .repos.service.remote):
    allow: $(settings__get '.repos.service.packages | tojson')
  $(settings__get .repos.fixture.remote): {}
EOF
}

################################################################################
# Replaces the config and waits for the poll the push triggers.
# Inputs:
#   config/repos.yaml content on stdin.
# Outputs:
#   The triggered poll's run id on stdout (nothing when the config didn't change).
# Returns:
#   0, or 1 when the push failed or its poll didn't run.
################################################################################
distributor__config_push() {
  local repo dir sha id
  repo=$(settings__get .repos.distributor.remote)
  dir=$(mktemp -d)
  git__clone "$repo" "$dir/repo" || return 1
  cat > "$dir/repo/config/repos.yaml"
  if git -C "$dir/repo" diff --quiet; then
    log__info "config unchanged"
    return 0
  fi
  git__commit "$dir/repo" "it: config" || return 1
  git__push_main "$dir/repo" "$repo" || return 1
  sha=$(git -C "$dir/repo" rev-parse HEAD)
  wait__until "poll triggered by config ${sha:0:7}" poll__has_push_run "$sha" || return 1
  id=$(poll__push_run "$sha")
  log__info "poll run: https://github.com/$repo/actions/runs/$id"
  github__run_wait "$repo" "$id" > /dev/null || return 1
  echo "$id"
}

################################################################################
# Runs a command in a clone of the distributor, commits what it changed, pushes, and waits for
# what the push triggers. GIT_COMMITTER_DATE, when set, backdates the commit.
# Arguments:
#   Commit message, then the command and its arguments.
# Returns:
#   0, or 1 when the command, the push, or the triggered runs failed to finish.
################################################################################
distributor__edit() {
  local repo dir
  repo=$(settings__get .repos.distributor.remote)
  dir=$(mktemp -d)
  git__clone "$repo" "$dir/repo" || return 1
  if ! (cd "$dir/repo" && "${@:2}"); then
    log__error "can't edit $repo: ${*:2}"
    return 1
  fi
  git__commit "$dir/repo" "it: $1" || return 1
  git__push_main "$dir/repo" "$repo" || return 1
  github__wait_idle "$repo"
}

################################################################################
# Counts the distributor's issues with an exact title, optionally in one state.
# Arguments:
#   Title, state (OPEN or CLOSED; optional).
# Outputs:
#   The count on stdout.
################################################################################
distributor__issue_count() {
  github__issues "$(settings__get .repos.distributor.remote)" |
    jq --arg t "$1" --arg s "${2:-}" '[.[] | select(.title == $t and ($s == "" or .state == $s))]
      | length'
}

################################################################################
# Whether the distributor has an open issue for denying a repo key.
# Arguments:
#   Repo path (owner/name) of the service repo, the key's fingerprint.
# Returns:
#   0 when there is one, 1 otherwise.
################################################################################
distributor__has_denial() {
  github__issues "$(settings__get .repos.distributor.remote)" |
    jq -e --arg p "Denied repo key: $1 $2 (" \
      'any(.[]; .state == "OPEN" and (.title | startswith($p)))' > /dev/null
}
