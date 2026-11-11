#!/usr/bin/env bash
# Runs the distributor's CI integration tests (ci/cases/*.bats) against the throwaway repos.
#
#   ci/run.sh                        every test
#   ci/run.sh retention noop         these tests (file names, .bats optional)
#   ci/run.sh --filter 'deny'        bats options pass through
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
  case ${1:-} in
    -h | --help)
      launch__usage "$0"
      return 0
      ;;
  esac
  launch__run ci "$@"
}

main "$@"
