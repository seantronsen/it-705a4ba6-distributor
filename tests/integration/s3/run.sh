#!/usr/bin/env bash
# Runs the S3 tests (s3/cases/*.bats): CI tests with the distributor publishing to a real test
# bucket, read back over its public HTTPS URL.
#
#   s3/init-aws.sh                       once: creates the bucket and its IAM user
#   s3/run.sh                        every test
#   s3/run.sh rekey                  these tests (file names, .bats optional)
#   s3/destroy-aws.sh                    deletes the bucket and the user
#
# Needs, besides the CI tests' requirements, the bucket and its credentials, from s3/init-aws.sh's
# state file. Without one: s3.bucket, s3.region, and s3.url (the bucket's public base URL) in
# your config, and credentials scoped to the bucket in AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY. With a state file, only its credentials are used (the environment's
# may be an admin's); your config's s3 settings win over the state file's. The credentials are set
# as the distributor's secrets from here, on the host; the container never sees them. The
# bucket's contents are overwritten.
#
# WARNING: like distro/run.sh, the tools container gets your rootless podman's API socket
# (install.bats installs from the bucket in distro containers). Review s3/ before running it.
set -uo pipefail

# shellcheck source=../lib/launch.sh
source "$(dirname "$0")/../lib/launch.sh"
# shellcheck source=lib/aws.sh
source "$(dirname "$0")/lib/aws.sh"

################################################################################
# Points the run at a copy of your config with the state file's s3 settings, unless your config
# sets s3 or there's no state file.
# Globals:
#   IT_CONFIG: set to the copy (a temporary file; no secrets)
#   S3_RUN_COPY: the copy's path, for main to delete
# Returns:
#   0, or 1 when a file can't be read or written.
################################################################################
s3_run__use_state_settings() {
  local user=null copy
  if config__has .s3 || [[ ! -f $(aws__state_file) ]]; then return 0; fi
  if [[ -f $(config__file) ]]; then user=$(config__json "$(config__file)") || return 1; fi
  copy=$(mktemp) || return 1
  if ! jq -n --argjson u "$user" --slurpfile s "$(aws__state_file)" \
    '($u // {}) + {s3: ($s[0] | {bucket, region, url})}' > "$copy"; then
    rm -f "$copy"
    return 1
  fi
  export IT_CONFIG=$copy
  S3_RUN_COPY=$copy
}

################################################################################
# One of the bucket's credentials: from the state file when there is one (never falling back
# to the environment, which may hold an admin's), else the environment.
# Arguments:
#   Variable name (AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY).
# Outputs:
#   The value on stdout, empty when missing.
################################################################################
s3_run__credential() {
  local field=${1#AWS_}
  if [[ -f $(aws__state_file) ]]; then
    aws__state ".${field,,}"
  else
    printf '%s' "${!1:-}"
  fi
}

################################################################################
# Sets the bucket's credentials as the distributor's secrets. Secrets reach gh on stdin only.
# Returns:
#   0, or 1 when a setting or credential is missing or a secret wasn't set.
################################################################################
s3_run__set_secrets() {
  local repos repo name failed=false
  for name in .s3.bucket .s3.region .s3.url; do config__get "$name" > /dev/null || failed=true; done
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z $(s3_run__credential "$name") ]]; then
      log__error "needs $name (the test bucket's credentials): run s3/init-aws.sh"
      failed=true
    fi
  done
  $failed && return 1
  repos=$(launch__repos) || return 1
  repo=$(jq -r .distributor <<< "$repos")
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if ! s3_run__credential "$name" | gh secret set "$name" -R "$repo"; then
      log__error "can't set $name on $repo"
      return 1
    fi
  done
}

main() {
  local status
  case ${1:-} in
    -h | --help)
      launch__usage "$0"
      return 0
      ;;
  esac
  s3_run__use_state_settings || return 1
  s3_run__set_secrets || return 1
  launch__run s3 --engine-socket "$@"
  status=$?
  [[ -n ${S3_RUN_COPY:-} ]] && rm -f "$S3_RUN_COPY"
  return "$status"
}

main "$@"
