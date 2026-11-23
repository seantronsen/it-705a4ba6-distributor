# shellcheck shell=bash
# The config: config/repos.yaml, checked against config/repos.schema.json.

[[ -n ${_LIB_CONFIG_SH:-} ]] && return 0
_LIB_CONFIG_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

################################################################################
# Whether a config setting is set.
# Arguments:
#   <jq path>
################################################################################
config__has() {
  yq -o=json -I=0 . "$CONFIG" | jq -e "$1 != null" > /dev/null
}

################################################################################
# One config setting. Exits when it isn't set: the schema says what's required, so the scripts
# carry no defaults.
# Arguments:
#   <jq path>, e.g. .repos or .target.s3.bucket
# Outputs:
#   The value on stdout: scalars raw, objects and arrays as JSON.
################################################################################
config__get() {
  yq -o=json -I=0 . "$CONFIG" \
    | jq -r "$1"' | if . == null then error("unset") elif type == "object" or type == "array"
        then tojson else . end' 2> /dev/null \
    || log__fatal "config: $1 isn't set"
}

