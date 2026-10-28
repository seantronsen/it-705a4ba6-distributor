#!/usr/bin/env bash
# Entry point inside every tools container (fedora). Started by run-integration-test, never by
# hand.
#
#   entry.sh setup | teardown | case <id>
#
# Reads the GitHub token (line 1) and the optional dummy account's token (line 2) from stdin, so
# neither is ever in the environment the container engine records, a file, or a command line.
set -euo pipefail

IFS= read -r GH_TOKEN || true
IFS= read -r IT_DUMMY_TOKEN || true
[[ -n $GH_TOKEN ]] || { echo "error: no GitHub token on stdin" >&2; exit 2; }
export GH_TOKEN IT_DUMMY_TOKEN

finish() {
  local rc=$?
  # A case's own cleanup (restoring a secret, dropping crafted releases) runs pass or fail.
  if declare -F case_cleanup > /dev/null; then (case_cleanup) || true; fi
  gpgconf --kill all 2> /dev/null || true
  # Docker runs as root: hand the shared files back to the host user.
  [[ -z ${IT_CHOWN:-} ]] || chown -R "$IT_CHOWN" /it-run /it-out 2> /dev/null || true
  exit "$rc"
}
trap finish EXIT

# Tools: one dnf install; packages are cached in the run's RAM-backed directory between phases.
echo 'keepcache=True' >> /etc/dnf/dnf.conf
dnf -y -q install gh git-core gnupg2 jq yq rpm-build dpkg > /dev/null 2>&1 \
  || { echo "error: dnf install failed" >&2; exit 2; }

# git authenticates through GH_TOKEN, configured in the environment only (no .gitconfig), and
# trusts the read-only source mounts whatever their owner.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
export GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1='*'
export GIT_CONFIG_KEY_2=advice.detachedHead GIT_CONFIG_VALUE_2=false

LIB=$(dirname "$0")
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=keys.sh
source "$LIB/keys.sh"
# shellcheck source=repos.sh
source "$LIB/repos.sh"
# shellcheck source=poll.sh
source "$LIB/poll.sh"
# shellcheck source=releases.sh
source "$LIB/releases.sh"
# shellcheck source=case.sh
source "$LIB/case.sh"
mkdir -p "$RUN/results"

case ${1:-} in
  setup)
    guard
    keys_create
    for repo in "$D" "$T" "$S"; do wipe "$repo"; done
    secrets_set
    seed
    # The seed's config push triggers a poll; let it finish so cases start idle.
    wait_for "$D: seed poll done" runs_idle "$D" || exit 2
    ;;
  teardown)
    guard
    for repo in "$D" "$T" "$S"; do wipe "$repo"; done
    secrets_delete
    ;;
  case)
    CASE=${2:?case id required}
    file=$(compgen -G "/suite/cases/$CASE-*.sh") || { echo "error: no case $CASE" >&2; exit 2; }
    : > "$RUN/results/$CASE.runs"
    # shellcheck source=/dev/null
    source "$file"
    wait_for "$D: idle before case $CASE" runs_idle "$D" || exit 2
    case_main
    ;;
  *)
    echo "usage: entry.sh setup | teardown | case <id>" >&2
    exit 2
    ;;
esac
