# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
# The state: state/state.json, checked against schemas/state.schema.json.

[[ -n "${_LIB_STATE_SH:-}" ]] && return 0
_LIB_STATE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

################################################################################
# The state.
# Outputs:
#   The JSON on stdout.
################################################################################
state__json() {
  cat "${STATE}"
}
