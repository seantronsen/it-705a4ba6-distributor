# shellcheck shell=bash
# The config: config/distributor.yaml, checked against schemas/distributor.schema.json. Read
# once, with each repo's omitted settings filled from the schema's defaults, into CONFIG_JSON
# (exported, so child processes such as publish's parallel uploads reuse it).

[[ -n ${_LIB_CONFIG_SH:-} ]] && return 0
_LIB_CONFIG_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

if [[ -z ${CONFIG_JSON:-} ]]; then
  CONFIG_JSON=$(yq -o=json -I=0 . "$CONFIG" \
    | base__jq -c --slurpfile s "$ROOT/schemas/distributor.schema.json" \
      'import "config" as config; config::fill_repo_defaults($s[0])') \
    || log__fatal "can't read $CONFIG"
  export CONFIG_JSON
fi

################################################################################
# Whether a config setting is set.
# Arguments:
#   <jq path>
################################################################################
config__has() {
  jq -e "$1 != null" <<< "$CONFIG_JSON" > /dev/null
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
  jq -r "$1"' | if . == null then error("unset") elif type == "object" or type == "array"
    then tojson else . end' <<< "$CONFIG_JSON" 2> /dev/null || log__fatal "config: $1 isn't set"
}

