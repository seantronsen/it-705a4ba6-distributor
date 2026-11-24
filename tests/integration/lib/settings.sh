# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
# The run's settings inside the tools container: the configuration the launcher writes, plus the
# run's own values under .run.

[[ -n "${_IT_SETTINGS_SH:-}" ]] && return 0
_IT_SETTINGS_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

################################################################################
# Where the settings file is in the container.
# Outputs:
#   The path on stdout.
################################################################################
settings__file() { echo /run/distributor-it/settings.json; }

################################################################################
# Whether a setting is set (some are optional, like .run.engine).
# Arguments:
#   jq path.
# Returns:
#   0 when set, 1 when not.
################################################################################
settings__has() {
  jq -e "$1 != null" "$(settings__file)" > /dev/null 2>&1
}

################################################################################
# One setting.
# Arguments:
#   jq path (e.g. .wait.timeout, .run.engine).
# Outputs:
#   The value on stdout.
# Returns:
#   0, or 1 when it isn't set.
################################################################################
settings__get() {
  if ! jq -r "$1"' | if . == null then error("unset") else . end' "$(settings__file)" \
    2> /dev/null; then
    log__error "$1 isn't set in $(settings__file)"
    return 1
  fi
}
