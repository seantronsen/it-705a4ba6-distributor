#!/usr/bin/env bash
# Runs the pipeline tests (pipeline/cases/*.bats) against the throwaway repos and the test bucket.
#
#   pipeline/run.sh                  every test
#   pipeline/run.sh retention noop   these tests (file names, .bats optional)
#   pipeline/run.sh --filter 'deny'  bats options pass through
#
# Every test publishes to the test bucket: from init-aws.sh (run it once), or s3.bucket,
# .region, and .url in your config with credentials scoped to the bucket in AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY. They're set as the distributor's secrets from the host; the container
# never sees them. The bucket's contents are overwritten.
#
# Runs in one transient tools container without the container engine; git pushes through your
# SSH agent. Logs go to stderr; results (TAP) to stdout and <output_dir>/<run id>/report.tap,
# with exported files in artifacts/ there.
#
# Settings: config.defaults.yaml, overridden by ~/.config/distributor-it/config.yaml.
set -uo pipefail

# shellcheck source=../lib/launch.sh
source "$(dirname "$0")/../lib/launch.sh"

main() {
  case "${1:-}" in
    -h | --help)
      launch__usage "$0"
      return 0
      ;;
  esac
  launch__run pipeline "$@"
}

main "$@"
