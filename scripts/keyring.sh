#!/usr/bin/env bash
# Build the openchami-keyring rpm and deb as an admit dir, so publish and record handle it like an
# admitted release.
#
#   keyring.sh <outdir>
#
# Packages every public key in keys/ (the throwaway archive key without keys/archive.asc) with
# nfpm, at the latest keyring version in state with the patch bumped (1.0.0 first). Writes
# <outdir>/result.json and <outdir>/files/.
source "$(dirname "$0")/lib.sh"

KEYRING=openchami-keyring

# The next version: the latest openchami-keyring@<version> in state, patch bumped.
next_version() {
  state_json | jql -r --arg n "$KEYRING@" 'include "lib";
    [keys[] | select(startswith($n)) | ltrimstr($n) | semver]
    | (max // [1, 0, -1]) | "\(.[0]).\(.[1]).\(.[2] + 1)"'
}

# Every key to package, as one armored file.
export_keys() { # <dest>
  local home keys=("$ROOT"/keys/*.asc) k
  [[ -f $ROOT/keys/archive.asc ]] || keys=("$ARCHIVE_PUB")
  home=$(mktemp -d)
  chmod 700 "$home"
  for k in "${keys[@]}"; do gpg --homedir "$home" --batch --quiet --import "$k" 2> /dev/null; done
  gpg --homedir "$home" --batch --armor --export > "$1"
  [[ -s $1 ]] || die "no keys to package"
}

# result.json for the built packages, the shape admit writes.
write_result() { # <version> <files dir> <dest>
  local f pkgs='[]'
  for f in "$2"/*; do
    pkgs=$(jq -c --argjson i "$(package_info "$f")" --arg sha "$(sha256sum "$f" | cut -d' ' -f1)" \
      '. + [$i + {sha256: $sha, path: "files/\($i.filename)", status: "published"}]' <<< "$pkgs")
  done
  jq -n --arg repo "$KEYRING" --arg v "$1" --arg at "$(now)" --arg run "$(run_url)" \
    --argjson p "$pkgs" '{key: "\($repo)@\($v)", repo: $repo, tag: $v, status: "published",
      at: $at, run: $run, repo_key: null, reasons: [], packages: $p}' > "$3"
}

[[ $# -eq 1 ]] || die "usage: keyring.sh <outdir>"
mkdir -p "$1/files"
out=$(cd "$1" && pwd)

target_init
archive_key_init
version=$(next_version)
mkdir -p "$ROOT/keyring/build"
export_keys "$ROOT/keyring/build/keys.asc"
for fmt in rpm deb; do
  (cd "$ROOT" && KEYRING_VERSION=$version nfpm package -f keyring/nfpm.yaml -p "$fmt" \
    -t "$out/files/" > /dev/null) || die "nfpm failed to build the $fmt keyring"
done
write_result "$version" "$out/files" "$out/result.json"
log "keyring: built $KEYRING@$version"
