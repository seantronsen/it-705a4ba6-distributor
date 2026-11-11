# shellcheck shell=bash
# Logging for every script in the suites, on the host and in containers: timestamped lines on
# stderr, tagged with the running test's name inside bats.

[[ -n ${_IT_LOG_SH:-} ]] && return 0
_IT_LOG_SH=1

################################################################################
# Writes one log line at a level.
# Globals:
#   IT_LOG_FD, BATS_TEST_DESCRIPTION
# Arguments:
#   Level (INFO, ERROR, FATAL), then message words.
# Outputs:
#   "[HH:MM:SS] <LEVEL> <test>: <message>" on IT_LOG_FD, or stderr.
################################################################################
log__base() {
  local level=$1 tag=${BATS_TEST_DESCRIPTION:+$BATS_TEST_DESCRIPTION: }
  shift
  # Inside bats, stderr is captured per test: run-in-container.sh opens IT_LOG_FD on the real one.
  TZ=UTC printf '[%(%H:%M:%S)T] %s %s%s\n' -1 "$level" "$tag" "$*" >&"${IT_LOG_FD:-2}"
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
# Logs an error and exits. For scripts only; library functions return instead.
# Arguments:
#   Message words.
################################################################################
log__fatal() {
  log__base FATAL "$*"
  exit 1
}
