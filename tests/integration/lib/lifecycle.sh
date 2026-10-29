# shellcheck shell=bash
# The suite's lifecycle on the throwaway repos: preparing them once per run, resetting them to a
# clean baseline before every test, and cleaning them at the end of the run.

[[ -n ${_IT_LIFECYCLE_SH:-} ]] && return 0
_IT_LIFECYCLE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"
source "$(dirname "${BASH_SOURCE[0]}")/keys.sh"
source "$(dirname "${BASH_SOURCE[0]}")/distributor.sh"
source "$(dirname "${BASH_SOURCE[0]}")/testbed.sh"

#######################################
# Refuses anything that isn't clearly one of the suite's repos: public (the distributor reads
# the service repos without their tokens), not a fork, and either empty or carrying the marker.
# Returns:
#   0 when all three repos pass, 1 otherwise.
#######################################
lifecycle__guard() {
  local repo info
  for repo in "$(suite__distributor_repo)" "$(suite__testbed_repo)" "$(suite__service2_repo)"; do
    info=$(gh api "repos/$repo") || log__error "$repo: not found" || return 1
    [[ $(jq -r .visibility <<< "$info") == public ]] || log__error "$repo: not public" || return 1
    [[ $(jq -r .fork <<< "$info") == false ]] || log__error "$repo: a fork" || return 1
    # An empty repo has no commits yet; anything else must carry the marker.
    if gh api "repos/$repo/commits?per_page=1" > /dev/null 2>&1 &&
      ! gh api "repos/$repo/contents/$(suite__marker)" > /dev/null 2>&1; then
      log__error "$repo: has history but no $(suite__marker); refusing to overwrite it"
      return 1
    fi
  done
}

#######################################
# Prepares the repos for a run: a new key chain and secrets, everything wiped (runs too), and
# the local checkouts force-pushed. The second service repo only holds crafted releases, so it
# gets just the marker.
# Returns:
#   0, or 1 when any step failed.
#######################################
lifecycle__setup_suite() {
  local repo dir
  lifecycle__guard || return 1
  keys__create || return 1
  for repo in "$(suite__distributor_repo)" "$(suite__testbed_repo)" "$(suite__service2_repo)"; do
    github__wipe "$repo" runs || return 1
  done
  keys__set_secrets || return 1
  testbed__seed || return 1
  dir=$(mktemp -d)
  git -C "$dir" init --quiet &&
    echo distributor-it > "$dir/$(suite__marker)" &&
    git__commit "$dir" "it: marker" &&
    git__push_main "$dir" "$(suite__service2_repo)" --force || return 1
  distributor__seed
}

#######################################
# Resets the repos to the baseline every test starts from: no releases, tags, issues, or
# distributor labels on any repo, the archive key secret intact, and the distributor on its seed
# commit (default config, empty state) with no poll running. The testbed's own CI may still be
# running from the seed push; nothing waits for it, since only its release workflow matters.
# Returns:
#   0, or 1 when any step failed.
#######################################
lifecycle__reset() {
  local repo
  for repo in "$(suite__distributor_repo)" "$(suite__testbed_repo)" "$(suite__service2_repo)"; do
    github__wipe "$repo" || return 1
  done
  keys__set_archive_secret valid || return 1
  distributor__reset
}

#######################################
# Cleans the repos after a run: everything wiped (runs too) and the secrets deleted. Skipped
# when IT_KEEP is set, to inspect what the run left.
# Globals:
#   IT_KEEP
# Returns:
#   0, or 1 when cleaning failed.
#######################################
lifecycle__teardown_suite() {
  local repo failed=0
  if [[ ${IT_KEEP:-false} == true ]]; then
    log__info "keep is set: leaving the repos as the run left them"
    return 0
  fi
  lifecycle__guard || return 1
  for repo in "$(suite__distributor_repo)" "$(suite__testbed_repo)" "$(suite__service2_repo)"; do
    github__wipe "$repo" runs || failed=1
  done
  keys__delete_secrets || failed=1
  ((failed == 0))
}
