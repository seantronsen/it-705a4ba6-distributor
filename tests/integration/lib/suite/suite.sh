# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
# Small helpers on the run's settings.

[[ -n "${_IT_SUITE_SH:-}" ]] && return 0
_IT_SUITE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../settings.sh"

################################################################################
# A repo's name without its owner, lowercased, as admit compares package names.
# Arguments:
#   Repo path (owner/name)
# Outputs:
#   The name on stdout.
################################################################################
suite__repo_name() {
  local name="${1#*/}"
  echo "${name,,}"
}

################################################################################
# The file every repo the suite pushes carries, so the guard knows it's the suite's.
# Outputs:
#   The file name on stdout.
################################################################################
suite__marker() { echo .distributor-it; }

################################################################################
# Whether to leave the repos as the run left them (no end-of-run cleanup).
# Returns:
#   0 when keeping them, 1 otherwise.
################################################################################
suite__is_kept() { [[ "$(settings__get .keep_repos)" == true ]]; }
