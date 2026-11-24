#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Runs the client tests (clients/cases/*.bats): each distro's own package manager installs from
# the test bucket, in sibling containers.
#
#   clients/run.sh                   every test
#   clients/run.sh install           these tests (file names, .bats optional)
#
# Needs what pipeline/run.sh needs. WARNING: unlike pipeline/run.sh, the tools container gets
# your rootless podman's API socket, to start the distro containers. Review clients/ before
# running it.
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
  launch__run clients --engine-socket "$@"
}

main "$@"
