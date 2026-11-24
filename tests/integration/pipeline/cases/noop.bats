# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# A poll that finds nothing new skips admission and commits nothing.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a poll with nothing new changes nothing" {
  local role=fixture repo distributor before run
  repo="$(settings__get ".repos.${role}.remote")"
  distributor="$(settings__get .repos.distributor.remote)"
  crafted__release_create "${role}" v1.0.0 "$(suite__repo_name "${repo}") 1.0.0"
  poll__run > /dev/null
  before="$(github__head_sha "${distributor}")"
  run="$(poll__run)"
  wait__check "poll succeeded" test "$(github__run_wait "${distributor}" "${run}")" = success
  wait__check "admit skipped" github__has_jobs_concluded "${distributor}" "${run}" admit skipped
  wait__check "no state commit" test "$(github__head_sha "${distributor}")" = "${before}"
}
