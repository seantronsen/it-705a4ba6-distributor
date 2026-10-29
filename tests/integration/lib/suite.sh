# shellcheck shell=bash
# The suite's settings, read from the environment run.sh passes to the tools container. Every
# other lib file gets the repo names, directories, and timings from these functions.

[[ -n ${_IT_SUITE_SH:-} ]] && return 0
_IT_SUITE_SH=1

#######################################
# The throwaway repos, as owner/name.
# Globals:
#   IT_DISTRIBUTOR_REPO, IT_TESTBED_REPO, IT_SERVICE2_REPO
# Outputs:
#   owner/name on stdout.
#######################################
suite__distributor_repo() { echo "$IT_DISTRIBUTOR_REPO"; }
suite__testbed_repo() { echo "$IT_TESTBED_REPO"; }
suite__service2_repo() { echo "$IT_SERVICE2_REPO"; }

#######################################
# A repo's name without its owner, lowercased, as admit compares package names.
# Arguments:
#   owner/name
# Outputs:
#   The name on stdout.
#######################################
suite__repo_name() {
  local name=${1#*/}
  echo "${name,,}"
}

#######################################
# The run's shared directory: the same path on the host and in the tools container, so sibling
# containers (install checks) can mount files from it. Holds the GnuPG home and fingerprints.
# Globals:
#   IT_SHARE_DIR
# Outputs:
#   The path on stdout.
#######################################
suite__share_dir() { echo "$IT_SHARE_DIR"; }

#######################################
# The file every repo the suite pushes carries, so the guard and destroy.sh know it's theirs.
# Outputs:
#   The file name on stdout.
#######################################
suite__marker() { echo .distributor-it; }

#######################################
# Waiting: the longest any single wait may take, and the pause between checks, in seconds.
# Globals:
#   IT_TIMEOUT, IT_POLL_INTERVAL
# Outputs:
#   Seconds on stdout.
#######################################
suite__timeout() { echo "${IT_TIMEOUT:-3600}"; }
suite__poll_interval() { echo "${IT_POLL_INTERVAL:-10}"; }

#######################################
# The container images: tools (the suite itself, and the dnf install check) and Debian (the apt
# install check).
# Globals:
#   IT_TOOLS_IMAGE, IT_DEBIAN_IMAGE
# Outputs:
#   The image on stdout.
#######################################
suite__tools_image() { echo "$IT_TOOLS_IMAGE"; }
suite__debian_image() { echo "$IT_DEBIAN_IMAGE"; }
