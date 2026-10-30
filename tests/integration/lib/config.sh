# shellcheck shell=bash
# The suites' configuration on the host: config.yaml (settings; the user's, never written) and
# the state file (the repos init.sh created), read with yq using syntax both yq implementations
# accept.

[[ -n ${_IT_CONFIG_SH:-} ]] && return 0
_IT_CONFIG_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

################################################################################
# The settings file.
# Globals:
#   IT_CONFIG (optional override)
# Outputs:
#   The path on stdout.
################################################################################
config__file() {
  echo "${IT_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/../config.yaml}"
}

################################################################################
# The state file: the repos init.sh created, kept outside the source tree.
# Globals:
#   IT_STATE (optional override), XDG_STATE_HOME
# Outputs:
#   The path on stdout.
################################################################################
config__state_file() {
  echo "${IT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/distributor-it/repos.yaml}"
}

################################################################################
# One value from a YAML file.
# Arguments:
#   File, yq path (e.g. .images.tools), default (optional).
# Outputs:
#   The value on stdout, or the default when it's missing or null.
# Returns:
#   0, or 1 when the file can't be read.
################################################################################
config__read() {
  local value
  if ! value=$(yq -r "$2 // \"\"" "$1"); then
    log__error "can't read $2 from $1"
    return 1
  fi
  echo "${value:-${3:-}}"
}

################################################################################
# One setting from the settings file.
# Arguments:
#   yq path, default (optional).
# Outputs:
#   The value on stdout.
# Returns:
#   0, or 1 when the file is missing or unreadable.
################################################################################
config__get() {
  if [[ ! -f $(config__file) ]]; then
    log__error "$(config__file) not found (copy config.example.yaml)"
    return 1
  fi
  config__read "$(config__file)" "$@"
}

################################################################################
# A throwaway repo: from the settings file when it sets repos (the source of truth), else from
# the state file init.sh wrote.
# Arguments:
#   Role: distributor, testbed, or service2.
# Outputs:
#   owner/name on stdout.
# Returns:
#   0, or 1 when neither names it.
################################################################################
config__repo() {
  local repo
  repo=$(config__get ".repos.$1") || return 1
  if [[ -z $repo && -f $(config__state_file) ]]; then
    repo=$(config__read "$(config__state_file)" ".$1") || return 1
  fi
  if [[ -z $repo ]]; then
    log__error "no $1 repo: run init.sh, or set repos.$1 in $(config__file)"
    return 1
  fi
  echo "$repo"
}
