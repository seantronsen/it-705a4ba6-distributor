# shellcheck shell=bash
# The suite's configuration on the host: config.yaml (settings) and repos.yaml (the repos
# init.sh created), read with yq using syntax both yq implementations accept.

[[ -n ${_IT_CONFIG_SH:-} ]] && return 0
_IT_CONFIG_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

#######################################
# The settings file and the repos file.
# Globals:
#   IT_CONFIG, IT_REPOS (optional overrides)
# Outputs:
#   The path on stdout.
#######################################
config__file() { echo "${IT_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/../config.yaml}"; }
config__repos_file() { echo "${IT_REPOS:-$(dirname "${BASH_SOURCE[0]}")/../repos.yaml}"; }

#######################################
# One value from a YAML file.
# Arguments:
#   File, yq path (e.g. .images.tools), default (optional).
# Outputs:
#   The value on stdout, or the default when it's missing or null.
#######################################
config__read() {
  local value
  value=$(yq -r "$2 // \"\"" "$1") || log__error "can't read $2 from $1" || return 1
  echo "${value:-${3:-}}"
}

#######################################
# One setting from the settings file.
# Arguments:
#   yq path, default (optional).
# Outputs:
#   The value on stdout.
# Returns:
#   0, or 1 when the file is missing or unreadable.
#######################################
config__get() {
  [[ -f $(config__file) ]] || log__error "$(config__file) not found (copy config.example.yaml)" ||
    return 1
  config__read "$(config__file)" "$@"
}

#######################################
# A throwaway repo: from repos.yaml when init.sh made the repos, else from the settings file.
# Arguments:
#   Role: distributor, testbed, or service2.
# Outputs:
#   owner/name on stdout.
# Returns:
#   0, or 1 when neither file names it.
#######################################
config__repo() {
  local repo=
  if [[ -f $(config__repos_file) ]]; then
    repo=$(config__read "$(config__repos_file)" ".$1") || return 1
  fi
  if [[ -z $repo ]]; then
    repo=$(config__get ".repos.$1") || return 1
  fi
  [[ -n $repo ]] || log__error "no $1 repo: run init.sh, or set repos.$1 in $(config__file)" ||
    return 1
  echo "$repo"
}
