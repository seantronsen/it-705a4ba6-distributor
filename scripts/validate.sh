#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Validate files against a JSON Schema, with the check-jsonschema pinned in
# schemas/requirements.txt. pipx run needs nothing on PATH.
#
#   validate.sh <schema> <file>...
source "$(dirname "$0")/lib/base.sh"

################################################################################
# Validates the files with the pinned check-jsonschema.
# Arguments:
#   <schema> <file>...
################################################################################
main() {
  local schema="$1"
  shift
  exec pipx run --spec "$(grep '^check-jsonschema==' "${ROOT}/schemas/requirements.txt")" \
    check-jsonschema --schemafile "${schema}" "$@"
}

[[ "$#" -ge 2 ]] || log__fatal "usage: validate.sh <schema> <file>..."
main "$@"
