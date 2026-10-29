# shellcheck shell=bash
# The throwaway distributor: seeding and resetting it, its config, polls, state, and its
# published repositories.

[[ -n ${_IT_DISTRIBUTOR_SH:-} ]] && return 0
_IT_DISTRIBUTOR_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/github.sh"

#######################################
# The default config: the testbed allowed its two packages, the second repo nothing extra.
# Outputs:
#   config/repos.yaml content on stdout.
#######################################
distributor__default_config() {
  cat << EOF
repos:
  - name: $(suite__testbed_repo)
    allow: [testbed, testbed-quadlet]
  - name: $(suite__service2_repo)
EOF
}

#######################################
# Pushes the local distributor checkout (mounted at /src/distributor) to the throwaway repo,
# with the default config, empty state, no cron schedule (tests dispatch every poll), and the
# marker. The seed commit stays in the shared directory for distributor__reset.
# Returns:
#   0, or 1 when the seed couldn't be pushed or its poll didn't finish.
#######################################
distributor__seed() {
  local dir poll
  dir="$(suite__share_dir)/seed-distributor"
  poll=$dir/.github/workflows/poll.yml
  rm -rf "$dir"
  git clone --quiet /src/distributor "$dir" || log__error "can't clone /src/distributor" || return 1
  distributor__default_config > "$dir/config/repos.yaml"
  echo '{}' > "$dir/state/state.json"
  sed -i '/^  schedule:$/,/^    - cron:/d' "$poll"
  if grep -q 'cron:' "$poll"; then
    log__error "can't drop poll's schedule"
    return 1
  fi
  echo distributor-it > "$dir/$(suite__marker)"
  git__commit "$dir" "it: seed" || return 1
  git__push_main "$dir" "$(suite__distributor_repo)" --force || return 1
  # The config change triggers a poll; tests start idle.
  github__wait_idle "$(suite__distributor_repo)"
}

#######################################
# Puts the distributor back on the seed commit (default config, empty state, unmodified code)
# when a test moved it, and waits until no poll runs.
# Returns:
#   0, or 1 when the push failed or a poll didn't finish.
#######################################
distributor__reset() {
  local dir repo
  dir="$(suite__share_dir)/seed-distributor"
  repo=$(suite__distributor_repo)
  github__wait_idle "$repo" || return 1
  if [[ $(github__head_sha "$repo") != "$(git -C "$dir" rev-parse HEAD)" ]]; then
    log__info "reset: $repo back to the seed commit"
    git__push_main "$dir" "$repo" --force || return 1
    # A config difference triggers a poll.
    github__wait_idle "$repo" || return 1
  fi
}

#######################################
# Replaces the config and waits for the poll the push triggers.
# Inputs:
#   config/repos.yaml content on stdin.
# Outputs:
#   The triggered poll's run id on stdout (nothing when the config didn't change).
# Returns:
#   0, or 1 when the push failed or its poll didn't run.
#######################################
distributor__push_config() {
  local repo dir sha id
  repo=$(suite__distributor_repo)
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
  wait__until "poll triggered by config ${sha:0:7}" distributor__has_push_run "$sha" || return 1
  id=$(distributor__push_run "$sha")
  log__info "poll run: https://github.com/$repo/actions/runs/$id"
  github__run_wait "$repo" "$id" > /dev/null || return 1
  echo "$id"
}

#######################################
# The poll run a push of a commit triggered.
# Arguments:
#   Commit SHA.
# Outputs:
#   The run id on stdout, or nothing yet.
#######################################
distributor__push_run() {
  gh api "repos/$(suite__distributor_repo)/actions/workflows/poll.yml/runs?event=push&head_sha=$1" \
    -q '.workflow_runs[0].id // empty'
}

#######################################
# Whether a push of a commit has triggered a poll yet.
# Arguments:
#   Commit SHA.
# Returns:
#   0 when it has, 1 otherwise.
#######################################
distributor__has_push_run() {
  [[ -n $(distributor__push_run "$1") ]]
}

#######################################
# The newest poll run's id, of any trigger.
# Outputs:
#   The id on stdout (0 when there is none).
#######################################
distributor__latest_poll() {
  gh api "repos/$(suite__distributor_repo)/actions/workflows/poll.yml/runs?per_page=1" \
    -q '.workflow_runs[0].id // 0'
}

#######################################
# Dispatched poll runs newer than a given run.
# Arguments:
#   Run id.
# Outputs:
#   Their ids on stdout, oldest first, one per line.
#######################################
distributor__dispatches_after() {
  gh api "repos/$(suite__distributor_repo)/actions/workflows/poll.yml/runs" \
    -X GET -f event=workflow_dispatch -f per_page=20 \
    -q "[.workflow_runs[] | select(.id > $1) | .id] | sort | .[]"
}

#######################################
# Whether at least <count> polls were dispatched after a given run.
# Arguments:
#   Run id, count.
# Returns:
#   0 when they were, 1 otherwise.
#######################################
distributor__has_dispatches_after() {
  (($(distributor__dispatches_after "$1" | wc -l) >= $2))
}

#######################################
# Dispatches polls without waiting for them to finish.
# Arguments:
#   How many.
# Outputs:
#   The new runs' ids on stdout, oldest first, one per line.
# Returns:
#   0, or 1 when they didn't start.
#######################################
distributor__dispatch() {
  local repo count=$1 before i id
  repo=$(suite__distributor_repo)
  before=$(distributor__latest_poll)
  for ((i = 0; i < count; i++)); do
    if ! gh workflow run poll.yml -R "$repo" --ref main > /dev/null; then
      log__error "can't dispatch poll"
      return 1
    fi
  done
  wait__until "$count dispatched poll(s) start" \
    distributor__has_dispatches_after "$before" "$count" || return 1
  for id in $(distributor__dispatches_after "$before" | head -n "$count"); do
    log__info "poll run: https://github.com/$repo/actions/runs/$id"
    echo "$id"
  done
}

#######################################
# Dispatches one poll and waits for it to finish.
# Outputs:
#   The run id on stdout.
# Returns:
#   0, or 1 when it didn't start or finish.
#######################################
distributor__poll() {
  local id
  id=$(distributor__dispatch 1) || return 1
  github__run_wait "$(suite__distributor_repo)" "$id" > /dev/null || return 1
  echo "$id"
}

#######################################
# The distributor's state.json on main.
# Outputs:
#   The JSON on stdout.
#######################################
distributor__state() {
  gh api -H 'Accept: application/vnd.github.raw' \
    "repos/$(suite__distributor_repo)/contents/state/state.json?ref=main"
}

#######################################
# Whether a jq filter holds for the state.
# Arguments:
#   jq options (e.g. --arg k value), then the filter last.
# Returns:
#   0 when the filter's result is true, 1 otherwise.
#######################################
distributor__state_has() {
  distributor__state | jq -e "$@" > /dev/null
}

#######################################
# A release's status in state.
# Arguments:
#   owner/name, tag.
# Outputs:
#   published, skipped, rejected, or absent, on stdout.
#######################################
distributor__release_status() {
  distributor__state | jq -r --arg k "$1@$2" '.[$k].status // "absent"'
}

#######################################
# Whether none of a repo's packages in state is published any more.
# Arguments:
#   owner/name
# Returns:
#   0 when none is, 1 otherwise.
#######################################
distributor__none_published() {
  distributor__state | jq -e --arg r "$1@" '
    all(to_entries[] | select(.key | startswith($r)) | .value.packages[]?; .status != "published")
  ' > /dev/null
}

#######################################
# Counts the distributor's issues with an exact title, optionally in one state.
# Arguments:
#   Title, state (OPEN or CLOSED; optional).
# Outputs:
#   The count on stdout.
#######################################
distributor__issue_count() {
  github__issue_count "$(suite__distributor_repo)" "$@"
}

#######################################
# Whether the distributor has an open issue for denying a repo key.
# Arguments:
#   owner/name of the service repo, the key's fingerprint.
# Returns:
#   0 when there is one, 1 otherwise.
#######################################
distributor__has_denial_issue() {
  github__issues "$(suite__distributor_repo)" | jq -e --arg p "Denied repo key: $1 $2 (" \
    'any(.[]; .state == "OPEN" and (.title | startswith($p)))' > /dev/null
}

#######################################
# Downloads the repositories a poll run published (its target-publish-* artifacts).
# Arguments:
#   Run id, destination directory (gets rpm/ and deb/, each the target with its keys/).
# Returns:
#   0, or 1 when a download failed.
#######################################
distributor__download_published() {
  local repo
  repo=$(suite__distributor_repo)
  {
    gh run download "$1" -R "$repo" -n target-publish-rpm -D "$2/rpm" &&
      gh run download "$1" -R "$repo" -n target-publish-deb -D "$2/deb"
  } || log__error "can't download run $1's published repositories"
}
