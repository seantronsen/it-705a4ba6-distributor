#!/usr/bin/env bash
# Runs the S3 tests (s3/cases/*.bats): CI tests with the distributor publishing to a real test
# bucket, read back over its public HTTPS URL.
#
#   s3/init-aws.sh                       once: creates the bucket and its IAM user
#   s3/run.sh                        every test
#   s3/run.sh rekey                  these tests (file names, .bats optional)
#   s3/destroy-aws.sh                    deletes the bucket and the user
#
# Needs, besides the CI tests' requirements, the bucket and its credentials: from s3/init-aws.sh,
# or s3.remote.bucket, .region, and .url in your config with credentials scoped to the bucket in
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. They're set as the distributor's secrets from the
# host; the container never sees them. The bucket's contents are overwritten.
#
# WARNING: like distro/run.sh, the tools container gets your rootless podman's API socket
# (install.bats installs from the bucket in distro containers). Review s3/ before running it.
set -uo pipefail

# shellcheck source=../lib/launch.sh
source "$(dirname "$0")/../lib/launch.sh"

################################################################################
# One of the bucket's credentials: from the credentials file when there is one, else the
# environment.
# Arguments:
#   Variable name (AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY).
# Outputs:
#   The value on stdout, empty when missing.
################################################################################
s3_run__credential() {
  local field=${1#AWS_} file
  file=$(config__file_state_s3_credentials)
  # Never falling back to the environment when the file exists: it may hold an admin's.
  if [[ -f $file ]]; then
    jq -r ".${field,,} // empty" "$file"
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
  local repo name failed=false
  for name in .s3.remote.bucket .s3.remote.region .s3.remote.url; do
    config__get "$name" > /dev/null || failed=true
  done
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z $(s3_run__credential "$name") ]]; then
      log__error "needs $name (the test bucket's credentials): run s3/init-aws.sh"
      failed=true
    fi
  done
  $failed && return 1
  repo=$(config__get .repos.distributor.remote) || return 1
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if ! s3_run__credential "$name" | gh secret set "$name" -R "$repo"; then
      log__error "can't set $name on $repo"
      return 1
    fi
  done
}

main() {
  case ${1:-} in
    -h | --help)
      launch__usage "$0"
      return 0
      ;;
  esac
  config__build || return 1
  s3_run__set_secrets || return 1
  launch__run s3 --engine-socket "$@"
}

main "$@"
