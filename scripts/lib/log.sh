# shellcheck shell=bash
# Logging for the distributor scripts: timestamped lines on stderr, so stdout stays the scripts'
# output. The same format as the integration suite's lib/log.sh, without its bats parts.

[[ -n ${_LIB_LOG_SH:-} ]] && return 0
_LIB_LOG_SH=1

################################################################################
# Writes one log line at a level.
# Arguments:
#   Level (INFO, ERROR, FATAL), then message words.
# Outputs:
#   "[HH:MM:SS] <LEVEL> <message>" (UTC) on stderr.
################################################################################
log__base() {
  local level=$1
  shift
  TZ=UTC printf '[%(%H:%M:%S)T] %s %s\n' -1 "$level" "$*" >&2
}

################################################################################
# Logs progress.
# Arguments:
#   Message words.
################################################################################
log__info() {
  log__base INFO "$@"
}

################################################################################
# Logs an error naming the function that reported it. It only logs: the caller returns.
# Arguments:
#   Message words.
################################################################################
log__error() {
  log__base ERROR "${FUNCNAME[1]:-main}: $*"
}

################################################################################
# Logs an error and exits 1. Library functions call it too, where a failure must stop the
# script.
# Arguments:
#   Message words.
################################################################################
log__fatal() {
  log__base FATAL "$*"
  exit 1
}
