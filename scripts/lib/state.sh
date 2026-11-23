# shellcheck shell=bash
# The state: STATE (state/state.json), checked against state/state.schema.json.

[[ -n ${_LIB_STATE_SH:-} ]] && return 0
_LIB_STATE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

################################################################################
# The state, or {} before the first record.
# Outputs:
#   The JSON on stdout.
################################################################################
state__json() {
  if [[ -s $STATE ]]; then cat "$STATE"; else echo '{}'; fi
}
