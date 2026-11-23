#!/usr/bin/env bash
# Validate files against a JSON Schema, with the check-jsonschema pinned in
# config/requirements.txt. pipx run needs nothing on PATH.
#
#   validate.sh <schema> <file>...
source "$(dirname "$0")/lib.sh"

[[ $# -ge 2 ]] || die "usage: validate.sh <schema> <file>..."

exec pipx run --spec "$(grep '^check-jsonschema==' "$ROOT/config/requirements.txt")" \
  check-jsonschema --schemafile "$1" "${@:2}"
