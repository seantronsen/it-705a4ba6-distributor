#!/usr/bin/env bash
# Runs the S3 tests (s3/cases/*.bats): CI tests with the distributor publishing to a real test
# bucket, read back over its public HTTPS URL.
#
#   s3/run.sh                        every test
#   s3/run.sh rekey                  these tests (file names, .bats optional)
#
# Needs, besides the CI tests' requirements: s3.bucket, s3.region, and s3.url (the bucket's
# public base URL) in your config, and the bucket's credentials (scoped to it) in
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. They're set as the distributor's secrets from
# here, on the host; the container never sees them. The bucket's contents are overwritten.
#
# WARNING: like distro/run.sh, the tools container gets your rootless podman's API socket
# (install.bats installs from the bucket in distro containers). Review s3/ before running it.
set -uo pipefail

# shellcheck source=../lib/launch.sh
source "$(dirname "$0")/../lib/launch.sh"

################################################################################
# Sets the bucket's credentials as the distributor's secrets. Secrets reach gh on stdin only.
# Globals:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
# Returns:
#   0, or 1 when a setting or credential is missing or a secret wasn't set.
################################################################################
s3_run__set_secrets() {
  local repos repo name failed=false
  for name in .s3.bucket .s3.region .s3.url; do config__get "$name" > /dev/null || failed=true; done
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z ${!name:-} ]]; then
      log__error "needs $name (the test bucket's credentials)"
      failed=true
    fi
  done
  $failed && return 1
  repos=$(launch__repos) || return 1
  repo=$(jq -r .distributor <<< "$repos")
  for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if ! printf '%s' "${!name}" | gh secret set "$name" -R "$repo"; then
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
  s3_run__set_secrets || return 1
  launch__run s3 --engine-socket "$@"
}

main "$@"
