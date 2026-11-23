# shellcheck shell=bash
# Logging for the distributor scripts: lines on stderr, so stdout stays the scripts' output.

[[ -n ${_LIB_LOG_SH:-} ]] && return 0
_LIB_LOG_SH=1

################################################################################
# Logs progress.
# Arguments:
#   Message words.
################################################################################
log__info() {
  printf '%s\n' "$*" >&2
}

################################################################################
# Logs an error and exits 1.
# Arguments:
#   Message words.
################################################################################
log__fatal() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
