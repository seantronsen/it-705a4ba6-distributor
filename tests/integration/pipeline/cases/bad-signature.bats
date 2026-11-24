# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# A release signed by a key the repo key never certified fails the trust chain.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a release with an uncertified signature is rejected" {
  local role=fixture repo reason
  repo="$(settings__get ".repos.${role}.remote")"
  reason="trust chain or checksums.txt signature didn't verify (see the run log)"
  crafted__release_create "${role}" v1.0.0 --foreign "$(suite__repo_name "${repo}") 1.0.0"
  poll__run > /dev/null
  wait__check "rejected" test "$(state__release_status "${repo}" v1.0.0)" = rejected
  wait__check "trust chain reason" state__has --arg k "${repo}@v1.0.0" \
    --arg r "${reason}" '.[$k].reasons == [$r]'
  wait__check "one issue" test "$(distributor__issue_count "Rejected release: ${repo}@v1.0.0")" = 1
}
