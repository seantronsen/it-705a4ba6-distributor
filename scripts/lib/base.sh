# shellcheck shell=bash
# The base every distributor script and lib/ module sources: strict mode, logging, paths, and
# constants. Source it; don't run it.
#
# Environment (all optional unless a script says otherwise):
#   GITHUB_TOKEN           gh's token for the GitHub API (releases, assets, runs, issues)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials for the config's `target.s3`
#   ARCHIVE_GPG_KEY        archive secret key, armored or base64 (required to sign)
#   ARCHIVE_GPG_PASSPHRASE its passphrase, if any
#   MASTER_PUBLIC_ASC, MASTER_FPR   root public key and fingerprint (admit)

[[ -n ${_LIB_BASE_SH:-} ]] && return 0
_LIB_BASE_SH=1

set -euo pipefail
# set -e in $(...) too: e.g. a signing failure inside meta=$(repo__rpm_metadata ...) fails the
# script instead of publishing an empty signature.
shopt -s inherit_errexit

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC2034 # used by the scripts that source this
{
  CONFIG=$ROOT/config/repos.yaml
  STATE=$ROOT/state/state.json
  SUITE=stable
  DEB_ARCHES=(amd64 arm64)
  # github-actions' trust-chain check, pinned by commit; Renovate updates the tag and commit.
  # renovate: datasource=github-tags depName=OpenCHAMI/github-actions currentValue=v4.0.0
  VERIFY_CHAIN_URL=https://raw.githubusercontent.com/OpenCHAMI/github-actions/ec67a926c858892c2e5e18fed111d7a7720384f3/scripts/gpg-verify-trust-chain.sh
}

################################################################################
# The current time.
# Outputs:
#   UTC, YYYY-MM-DDTHH:MM:SSZ, on stdout.
################################################################################
base__now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

################################################################################
# jq with the modules in scripts/jq/ available, e.g. `import "state" as state;`.
# Arguments:
#   jq's arguments.
################################################################################
base__jq() { jq -L "$ROOT/scripts/jq" "$@"; }
