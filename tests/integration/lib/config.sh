# shellcheck shell=bash
# The suites' configuration on the host: config.defaults.yaml overridden by the user's config
# file, plus the state files init.sh and s3/init-aws.sh write.

[[ -n ${_IT_CONFIG_SH:-} ]] && return 0
_IT_CONFIG_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

################################################################################
# The defaults file.
# Outputs:
#   The path on stdout.
################################################################################
config__file_defaults() {
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.defaults.yaml"
}

################################################################################
# The user's config file. It may not exist: then the defaults apply.
# Globals:
#   IT_CONFIG (optional override), XDG_CONFIG_HOME
# Outputs:
#   The path on stdout.
################################################################################
config__file_user() {
  echo "${IT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/distributor-it/config.yaml}"
}

################################################################################
# The repos state file: the repos init.sh created, kept outside the source tree.
# Globals:
#   IT_STATE (optional override), XDG_STATE_HOME
# Outputs:
#   The path on stdout.
################################################################################
config__file_state_repos() {
  echo "${IT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/distributor-it/repos.yaml}"
}

################################################################################
# The S3 bucket state file: the bucket s3/init-aws.sh created, kept outside the source tree.
# Globals:
#   IT_S3_STATE (optional override), XDG_STATE_HOME
# Outputs:
#   The path on stdout.
################################################################################
config__file_state_s3_bucket() {
  echo "${IT_S3_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/distributor-it/s3.json}"
}

################################################################################
# The S3 credentials state file: the access key of the IAM user s3/init-aws.sh created. Never
# merged into the configuration (which the run writes out); mode 600.
# Globals:
#   IT_S3_CREDENTIALS (optional override), XDG_STATE_HOME
# Outputs:
#   The path on stdout.
################################################################################
config__file_state_s3_credentials() {
  local dir=${XDG_STATE_HOME:-$HOME/.local/state}/distributor-it
  echo "${IT_S3_CREDENTIALS:-$dir/s3-credentials.json}"
}

################################################################################
# A YAML file as JSON, with either yq implementation.
# Arguments:
#   File.
# Outputs:
#   The JSON on stdout, on one line (null for an empty file).
# Returns:
#   0, or 1 when the file can't be read.
################################################################################
config__json() {
  local json
  # mikefarah's yq needs to be told; the jq-based one prints JSON anyway.
  if yq --version 2>&1 | grep -q mikefarah; then
    json=$(yq -o=json . "$1")
  else
    json=$(yq . "$1")
  fi || {
    log__error "can't read $1"
    return 1
  }
  jq -c . <<< "${json:-null}"
}

################################################################################
# Fails when a state file sets a setting the user's config also sets.
# Arguments:
#   The user's settings (JSON), the state file's (JSON), the state file.
# Returns:
#   0, or 1 on a conflict.
################################################################################
config__check_conflicts() {
  local conflicts
  conflicts=$(jq -rn --argjson u "$1" --argjson s "$2" '[$s | paths(scalars) as $p
    | select(($u // {}) | getpath($p) != null) | $p | map(tostring) | join(".")] | join(", ")')
  if [[ -n $conflicts ]]; then
    log__error "both $(config__file_user) and $3 set $conflicts: remove them from your config, or" \
      "destroy what the state file lists (or move it aside)"
    return 1
  fi
}

################################################################################
# Merges the configuration into IT_CONFIG_JSON, unless it's already there: the
# user's settings over the defaults, plus the state files'. A checkout the user
# sets replaces the default one whole (path, or repo and ref, never a mix).
# Globals:
#   IT_CONFIG_JSON (set and exported)
# Returns:
#   0, or 1 when a file can't be read or a state file and the user's config set the same setting.
################################################################################
config__build() {
  local defaults user=null repos='{}' bucket='{}'
  [[ -n ${IT_CONFIG_JSON:-} ]] && return 0
  defaults=$(config__json "$(config__file_defaults)") || return 1
  if [[ -f $(config__file_user) ]]; then
    user=$(config__json "$(config__file_user)") || return 1
  fi
  if [[ -f "$(config__file_state_repos)" ]]; then
    repos=$(config__json "$(config__file_state_repos)" | jq -c '{repos: map_values({remote: .})}') || return 1
    config__check_conflicts "$user" "$repos" "$(config__file_state_repos)" || return 1
  fi
  if [[ -f "$(config__file_state_s3_bucket)" ]]; then
    bucket=$(config__json "$(config__file_state_s3_bucket)" | jq -c '{s3: {remote: {bucket, region, url}}}') || return 1
    config__check_conflicts "$user" "$bucket" "$(config__file_state_s3_bucket)" || return 1
  fi
  IT_CONFIG_JSON=$(jq -cn --argjson d "$defaults" --argjson u "$user" --argjson r "$repos" \
    --argjson b "$bucket" '($u // {}) as $u
    | $d * $u * $r * $b
    | reduce ($u.repos // {} | to_entries[] | select(.value.checkout)) as $e
        (.; .repos[$e.key].checkout = $e.value.checkout)') || return 1
  export IT_CONFIG_JSON
}

################################################################################
# Whether a setting is set (the defaults leave some unset).
# Arguments:
#   jq path (e.g. .containers.engine).
# Returns:
#   0 when set, 1 when not or the configuration can't be read.
################################################################################
config__has() {
  config__build || return 1
  jq -e "$1 != null" <<< "$IT_CONFIG_JSON" > /dev/null
}

################################################################################
# One setting.
# Arguments:
#   jq path (e.g. .containers.images.tools).
# Outputs:
#   The value on stdout (objects as JSON).
# Returns:
#   0, or 1 when it isn't set or the configuration can't be read.
################################################################################
config__get() {
  config__build || return 1
  if ! jq -r "$1"' | if . == null then error("unset") else . end' <<< "$IT_CONFIG_JSON" \
    2> /dev/null; then
    log__error "$1 isn't set"
    return 1
  fi
}
