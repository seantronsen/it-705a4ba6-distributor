#!/usr/bin/env bash
# Runs the S3 tests (s3/cases/*.bats): CI tests that read the test bucket back over its public
# HTTPS URL, and install from it with each distro's package manager.
#
#   s3/init-aws.sh                       once: creates the bucket and its IAM user
#   s3/run.sh                        every test
#   s3/run.sh rekey                  these tests (file names, .bats optional)
#   s3/destroy-aws.sh                    deletes the bucket and the user
#
# Needs what ci/run.sh needs. WARNING: unlike ci/run.sh, the tools container gets your rootless
# podman's API socket (install.bats installs from the bucket in distro containers). Review s3/
# before running it.
set -uo pipefail

# shellcheck source=../lib/launch.sh
source "$(dirname "$0")/../lib/launch.sh"

main() {
  case ${1:-} in
    -h | --help)
      launch__usage "$0"
      return 0
      ;;
  esac
  launch__run s3 --engine-socket "$@"
}

main "$@"
