# shellcheck shell=bash
# The S3 suite's AWS resources, on the host: the state file s3/init-aws.sh writes (bucket, region,
# URL, the IAM user and its access key), read by s3/run.sh and s3/destroy-aws.sh. Mode 600: it
# holds the user's secret access key.

[[ -n ${_IT_AWS_SH:-} ]] && return 0
_IT_AWS_SH=1

################################################################################
# The state file, kept outside the source tree.
# Globals:
#   IT_S3_STATE (optional override), XDG_STATE_HOME
# Outputs:
#   The path on stdout.
################################################################################
aws__state_file() {
  echo "${IT_S3_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/distributor-it/s3.json}"
}

################################################################################
# One value from the state file.
# Arguments:
#   jq path (e.g. .bucket).
# Outputs:
#   The value on stdout, empty when missing.
# Returns:
#   0, or 1 when the file can't be read.
################################################################################
aws__state() {
  jq -r "$1 // empty" "$(aws__state_file)"
}

################################################################################
# Rewrites the state file through a jq filter, keeping its mode.
# Arguments:
#   jq options and filter (e.g. --arg k v '.key = $k').
# Returns:
#   0, or 1 when jq failed (the file is left as it was).
################################################################################
aws__state_set() {
  local file tmp
  file=$(aws__state_file)
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if ! jq "$@" "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

################################################################################
# The names s3/init-aws.sh gives the bucket and the user (the same name), for s3/destroy-aws.sh to
# refuse anything else.
# Outputs:
#   An extended regular expression on stdout.
################################################################################
aws__name_pattern() { echo '^distributor-it-[0-9a-f]{8}$'; }
