# shellcheck shell=bash
# The CI tests' settings, read from the environment the launcher passes to the tools container.
# Every other lib file gets the repo names, directories, and timings from these functions.

[[ -n ${_IT_SUITE_SH:-} ]] && return 0
_IT_SUITE_SH=1

################################################################################
# The throwaway repos, as owner/name.
# Globals:
#   IT_DISTRIBUTOR_REPO, IT_TESTBED_REPO, IT_SERVICE2_REPO
# Outputs:
#   owner/name on stdout.
################################################################################
suite__distributor_repo() { echo "$IT_DISTRIBUTOR_REPO"; }
suite__testbed_repo() { echo "$IT_TESTBED_REPO"; }
suite__service2_repo() { echo "$IT_SERVICE2_REPO"; }

################################################################################
# A repo's name without its owner, lowercased, as admit compares package names.
# Arguments:
#   owner/name
# Outputs:
#   The name on stdout.
################################################################################
suite__repo_name() {
  local name=${1#*/}
  echo "${name,,}"
}

################################################################################
# The run's shared directory, deleted when the run ends: the GnuPG home, fingerprints, the
# distributor's seed commit. The same path on the host, so sibling containers can mount from it.
# Globals:
#   IT_SHARE_DIR
# Outputs:
#   The path on stdout.
################################################################################
suite__share_dir() { echo "$IT_SHARE_DIR"; }

################################################################################
# Where tests export files for later stages (artifacts/<test name>/), kept after the run. The
# same path on the host.
# Globals:
#   IT_ARTIFACTS_DIR
# Outputs:
#   The path on stdout.
################################################################################
suite__artifacts_dir() { echo "$IT_ARTIFACTS_DIR"; }

################################################################################
# The file every repo the suite pushes carries, so the guard knows it's the suite's.
# Outputs:
#   The file name on stdout.
################################################################################
suite__marker() { echo .distributor-it; }

################################################################################
# Waiting: the longest any single wait may take, and the pause between checks, in seconds.
# Globals:
#   IT_TIMEOUT, IT_POLL_INTERVAL
# Outputs:
#   Seconds on stdout.
################################################################################
suite__timeout() { echo "${IT_TIMEOUT:-3600}"; }
suite__poll_interval() { echo "${IT_POLL_INTERVAL:-10}"; }
