#!/usr/bin/env bash
# Validate files against a JSON Schema, with the check-jsonschema pinned in
# config/requirements.txt. pipx run needs nothing on PATH.
#
#   validate.sh <schema> <file>...
source "$(dirname "$0")/lib/base.sh"

################################################################################
# Validates the files with the pinned check-jsonschema.
# Arguments:
#   <schema> <file>...
################################################################################
main() {
  local schema=$1
  shift
  exec pipx run --spec "$(grep '^check-jsonschema==' "$ROOT/config/requirements.txt")" \
    check-jsonschema --schemafile "$schema" "$@"
}

[[ $# -ge 2 ]] || log__fatal "usage: validate.sh <schema> <file>..."
main "$@"
