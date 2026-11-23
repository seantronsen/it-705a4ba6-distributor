#!/usr/bin/env bash
# Install nfpm, the pinned version checked against its checksum, for keyring.sh.
#
#   install-nfpm.sh <bin dir>
source "$(dirname "$0")/lib.sh"

NFPM_VERSION=2.48.0
NFPM_SHA256=6d7f9a28b2f397934403950fcbba83f598b08d02edbe79a0815b3b4897341750

[[ $# -eq 1 ]] || die "usage: install-nfpm.sh <bin dir>"
url=https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION
tgz=$(mktemp)
curl -fsSL -o "$tgz" "$url/nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"
echo "$NFPM_SHA256  $tgz" | sha256sum -c --quiet
mkdir -p "$1"
tar -xzf "$tgz" -C "$1" nfpm
rm -f "$tgz"
log "installed nfpm $NFPM_VERSION in $1"
