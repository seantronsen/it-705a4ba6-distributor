# shellcheck shell=bash
# The base every distributor script and lib/ module sources: strict mode, logging, paths, and
# constants. Source it; don't run it.
#
# Each script lists the environment it needs in its header and checks it with base__env_require.

[[ -n ${_LIB_BASE_SH:-} ]] && return 0
_LIB_BASE_SH=1

set -euo pipefail
# set -e in $(...) too: e.g. a signing failure inside meta=$(metadata__rpm_build ...) fails the
# script instead of publishing an empty signature.
shopt -s inherit_errexit

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC2034 # used by the scripts that source this
{
  CONFIG=$ROOT/config/repos.yaml
  STATE=$ROOT/state/state.json
  SUITE=stable
  # github-actions' trust-chain check, pinned by commit; Renovate updates the tag and commit.
  # renovate: datasource=github-tags depName=OpenCHAMI/github-actions currentValue=v4.0.0
  VERIFY_CHAIN_URL=https://raw.githubusercontent.com/OpenCHAMI/github-actions/ec67a926c858892c2e5e18fed111d7a7720384f3/scripts/gpg-verify-trust-chain.sh
}

################################################################################
# The current time.
# Outputs:
#   UTC, YYYY-MM-DDTHH:MM:SSZ, on stdout.
################################################################################
base__timestamp_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

################################################################################
# jq with the modules in scripts/jq/ available, e.g. `import "state" as state;`.
# Arguments:
#   jq's arguments.
################################################################################
base__jq() { jq -L "$ROOT/scripts/jq" "$@"; }

################################################################################
# Percent-encodes a string for a URL.
# Arguments:
#   The string.
# Outputs:
#   The encoded string on stdout.
################################################################################
base__uri_encode() {
  jq -rn --arg s "$1" '$s | @uri'
}

################################################################################
# Exits when any of the named environment variables is unset or empty, naming every missing one.
# Arguments:
#   <variable name>...
################################################################################
base__env_require() {
  local name missing=()
  for name in "$@"; do
    [[ -n ${!name:-} ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || log__fatal "missing environment: ${missing[*]}"
}
