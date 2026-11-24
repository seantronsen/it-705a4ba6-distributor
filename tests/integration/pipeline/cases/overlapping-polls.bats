# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Two polls dispatched together run one after the other: the first admits, the second finds
# nothing new and commits nothing.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

################################################################################
# Whether one of the distributor's recent commits was made by a run (its message ends with the
# run's URL).
# Arguments:
#   Run id.
# Returns:
#   0 when it was, 1 otherwise.
################################################################################
committed_by() {
  gh api "repos/$(settings__get .repos.distributor.remote)/commits?per_page=20" \
    -q '.[].commit.message' | grep -q "/runs/$1\$"
}

################################################################################
# The opposite of committed_by.
# Arguments:
#   Run id.
################################################################################
not_committed_by() {
  ! committed_by "$1"
}

@test "overlapping polls admit a release once" {
  local role=fixture repo distributor first second
  repo="$(settings__get ".repos.${role}.remote")"
  distributor="$(settings__get .repos.distributor.remote)"
  crafted__release_create "${role}" v1.0.0 "$(suite__repo_name "${repo}") 1.0.0"
  { read -r first && read -r second; } < <(poll__dispatch 2)
  github__run_wait "${distributor}" "${first}" > /dev/null
  github__run_wait "${distributor}" "${second}" > /dev/null
  wait__check "first poll admitted v1.0.0" \
    github__has_jobs_concluded "${distributor}" "${first}" "admit / admit" success
  wait__check "second poll found nothing new" \
    github__has_jobs_concluded "${distributor}" "${second}" admit skipped
  wait__check "v1.0.0: published" test "$(state__release_status "${repo}" v1.0.0)" = published
  wait__check "state committed by the first poll" committed_by "${first}"
  wait__check "no state commit by the second" not_committed_by "${second}"
}
