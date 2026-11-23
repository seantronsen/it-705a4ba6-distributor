# shellcheck shell=bash
# The CI tests' lifecycle on the throwaway repos: preparing them once per run, resetting them to
# a clean baseline before every test, and cleaning them at the end of the run.

[[ -n ${_IT_LIFECYCLE_SH:-} ]] && return 0
_IT_LIFECYCLE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../github.sh"
source "$(dirname "${BASH_SOURCE[0]}")/keys.sh"
source "$(dirname "${BASH_SOURCE[0]}")/distributor.sh"
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"

################################################################################
# Refuses anything that isn't clearly one of the suite's repos: public, not a fork, and either
# empty or carrying the marker. Reports every problem with every repo.
# Returns:
#   0 when all three repos pass, 1 otherwise.
################################################################################
lifecycle__guard() {
  local repo info failed=false
  for repo in $(settings__get '.repos[].remote'); do
    if ! info=$(gh api "repos/$repo"); then
      log__error "$repo: not found"
      failed=true
      continue
    fi
    # The distributor reads the service repos without their tokens.
    if [[ $(jq -r .visibility <<< "$info") != public ]]; then
      log__error "$repo: not public"
      failed=true
    fi
    if [[ $(jq -r .fork <<< "$info") != false ]]; then
      log__error "$repo: a fork"
      failed=true
    fi
    # An empty repo has no commits yet; anything else must carry the marker.
    if gh api "repos/$repo/commits?per_page=1" > /dev/null 2>&1 &&
      ! gh api "repos/$repo/contents/$(suite__marker)" > /dev/null 2>&1; then
      log__error "$repo: has history but no $(suite__marker); refusing to overwrite it"
      failed=true
    fi
  done
  ! $failed
}

################################################################################
# Prepares the repos for a run: a new key chain and secrets, everything wiped (runs too), and
# each repo seeded (lifecycle__seed_*).
# Returns:
#   0, or 1 when any step failed.
################################################################################
lifecycle__setup_suite() {
  local repo
  lifecycle__guard || return 1
  keys__create || return 1
  for repo in $(settings__get '.repos[].remote'); do
    github__wipe "$repo" runs || return 1
  done
  keys__set_secrets || return 1
  lifecycle__seed_service || return 1
  lifecycle__seed_fixture || return 1
  lifecycle__seed_distributor
}

################################################################################
# Pushes the service checkout to its throwaway repo, with its images moved to the owner's GHCR
# namespace, the marker, and the tag workflow.
# Returns:
#   0, or 1 when the push failed.
################################################################################
lifecycle__seed_service() {
  local repo owner dir
  repo=$(settings__get .repos.service.remote)
  owner=${repo%%/*}
  dir=$(mktemp -d)
  if ! git clone --quiet /src/service "$dir/repo"; then
    log__error "can't clone /src/service"
    return 1
  fi
  # Any of OpenCHAMI's service repos: .goreleaser.yaml or .yml, images named literally or by
  # template. One left in OpenCHAMI's namespace would push there.
  if ! sed -i -E "s|ghcr\.io/openchami/|ghcr.io/${owner,,}/|Ig" "$dir"/repo/.goreleaser.y*ml ||
    grep -q -i 'ghcr\.io/openchami/' "$dir"/repo/.goreleaser.y*ml; then
    log__error "can't move the images to ghcr.io/${owner,,}"
    return 1
  fi
  lifecycle__write_marker "$dir/repo"
  git__add_tag_workflow "$dir/repo"
  git__commit "$dir/repo" "it: seed" || return 1
  git__push_main "$dir/repo" "$repo" --force
}

################################################################################
# Pushes the fixture repo's seed: it only holds crafted releases, so just the marker and the tag
# workflow.
# Returns:
#   0, or 1 when the push failed.
################################################################################
lifecycle__seed_fixture() {
  local dir
  dir=$(mktemp -d)
  if ! git -C "$dir" init --quiet; then
    log__error "can't create the fixture's seed repo"
    return 1
  fi
  lifecycle__write_marker "$dir"
  git__add_tag_workflow "$dir"
  git__commit "$dir" "it: marker" || return 1
  git__push_main "$dir" "$(settings__get .repos.fixture.remote)" --force
}

################################################################################
# Pushes the distributor checkout to its throwaway repo, with the default config, empty state,
# no cron schedule, and the marker. The seed commit stays in the shared directory for
# lifecycle__reset_distributor.
# Returns:
#   0, or 1 when the seed couldn't be pushed or its poll didn't finish.
################################################################################
lifecycle__seed_distributor() {
  local dir poll
  dir="$(settings__get .run.share_dir)/seed-distributor"
  poll=$dir/.github/workflows/poll.yml
  rm -rf "$dir"
  if ! git clone --quiet /src/distributor "$dir"; then
    log__error "can't clone /src/distributor"
    return 1
  fi
  distributor__default_config > "$dir/config/repos.yaml"
  echo '{}' > "$dir/state/state.json"
  # Tests dispatch every poll.
  sed -i '/^  schedule:$/,/^    - cron:/d' "$poll"
  if grep -q 'cron:' "$poll"; then
    log__error "can't drop poll's schedule"
    return 1
  fi
  lifecycle__write_marker "$dir"
  git__commit "$dir" "it: seed" || return 1
  git__push_main "$dir" "$(settings__get .repos.distributor.remote)" --force || return 1
  # The config change triggers a poll; tests start idle.
  github__wait_idle "$(settings__get .repos.distributor.remote)"
}

################################################################################
# Writes the marker every repo the suite pushes carries (see lifecycle__guard).
# Arguments:
#   The repo's directory.
################################################################################
lifecycle__write_marker() {
  echo distributor-it > "$1/$(suite__marker)"
}

################################################################################
# Resets the repos to the baseline every test starts from: no releases, tags, issues, or
# distributor labels, the archive key secret intact, and the distributor on its seed commit with
# no poll running.
# Returns:
#   0, or 1 when any step failed.
################################################################################
lifecycle__reset() {
  local repo
  for repo in $(settings__get '.repos[].remote'); do
    github__wipe "$repo" || return 1
  done
  keys__set_archive_secret "$(keys__fpr archive)" || return 1
  # The service repo's own CI may still run from the seed push; only its release workflow matters.
  lifecycle__reset_distributor
}

################################################################################
# Checks the state a test left against its schema, once no poll runs. Every case that resets
# the repos calls it from its teardown.
# Returns:
#   0 when it's valid, 1 when it isn't or a poll didn't finish.
################################################################################
lifecycle__check_state() {
  github__wait_idle "$(settings__get .repos.distributor.remote)" && state__is_valid
}

################################################################################
# Puts the distributor back on the seed commit when a test moved it, and waits until no poll
# runs.
# Returns:
#   0, or 1 when the push failed or a poll didn't finish.
################################################################################
lifecycle__reset_distributor() {
  local dir repo
  dir="$(settings__get .run.share_dir)/seed-distributor"
  repo=$(settings__get .repos.distributor.remote)
  github__wait_idle "$repo" || return 1
  if [[ $(github__head_sha "$repo") != "$(git -C "$dir" rev-parse HEAD)" ]]; then
    log__info "reset: $repo back to the seed commit"
    git__push_main "$dir" "$repo" --force || return 1
    # A config difference triggers a poll.
    github__wait_idle "$repo" || return 1
  fi
}

################################################################################
# Cleans the repos after a run: everything wiped (runs too) and the secrets deleted. Skipped
# when keep is set, to inspect what the run left.
# Returns:
#   0, or 1 when cleaning failed.
################################################################################
lifecycle__teardown_suite() {
  local repo failed=false
  if suite__is_kept; then
    log__info "keep is set: leaving the repos as the run left them"
    return 0
  fi
  lifecycle__guard || return 1
  for repo in $(settings__get '.repos[].remote'); do
    github__wipe "$repo" runs || failed=true
  done
  keys__delete_secrets || failed=true
  if $failed; then
    return 1
  fi
}
