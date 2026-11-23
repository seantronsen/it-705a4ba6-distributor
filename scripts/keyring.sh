#!/usr/bin/env bash
# Build the openchami-keyring rpm and deb as an admit dir, so publish and record handle it like an
# admitted release.
#
#   keyring.sh <outdir>
#
# Packages every public key in keys/ (the archive public key without keys/archive.asc) with
# nfpm, at the latest keyring version in state with the patch bumped (1.0.0 first). Writes
# <outdir>/result.json and <outdir>/files/.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/keys.sh"
source "$(dirname "$0")/lib/package.sh"
source "$(dirname "$0")/lib/state.sh"

KEYRING=openchami-keyring

################################################################################
# The keyring's next version: its latest in state with the patch bumped, or 1.0.0.
# Outputs:
#   The version on stdout.
################################################################################
next_version() {
  state__json | base__jq -r --arg n "$KEYRING@" 'import "version" as version;
    [keys[] | select(startswith($n)) | ltrimstr($n) | version::parse_semver]
    | (max // [1, 0, -1]) | "\(.[0]).\(.[1]).\(.[2] + 1)"'
}

################################################################################
# Exports every key to package (keys/, or the archive public key without keys/archive.asc)
# into one armored file.
# Globals:
#   ARCHIVE_PUB (keys__archive_load)
# Arguments:
#   <dest>
################################################################################
export_keys() {
  local dest=$1 home keys=("$ROOT"/keys/*.asc) k
  [[ -f $ROOT/keys/archive.asc ]] || keys=("$ARCHIVE_PUB")
  home=$(mktemp -d)
  chmod 700 "$home"
  for k in "${keys[@]}"; do gpg --homedir "$home" --batch --quiet --import "$k" 2> /dev/null; done
  gpg --homedir "$home" --batch --armor --export > "$dest"
  [[ -s $dest ]] || log__fatal "no keys to package"
}

################################################################################
# Writes result.json for the built packages, in the shape admit writes.
# Arguments:
#   <version> <files dir> <dest>
################################################################################
write_result() {
  local version=$1 files=$2 dest=$3 f pkgs='[]'
  for f in "$files"/*; do
    pkgs=$(jq -c --argjson i "$(package__metadata "$f")" \
      --arg sha "$(sha256sum "$f" | cut -d' ' -f1)" \
      '. + [$i + {sha256: $sha, path: "files/\($i.filename)", status: "published"}]' <<< "$pkgs")
  done
  jq -n --arg repo "$KEYRING" --arg v "$version" --arg at "$(base__timestamp_utc)" \
    --arg run "$(github__current_run_url)" --argjson p "$pkgs" '{key: "\($repo)@\($v)", repo: $repo,
      tag: $v, status: "published", at: $at, run: $run, repo_key: null, reasons: [],
      packages: $p}' > "$dest"
}

################################################################################
# Builds the keyring at its next version into the admit dir.
# Arguments:
#   <outdir>
################################################################################
main() {
  local out version fmt
  mkdir -p "$1/files"
  out=$(cd "$1" && pwd)
  keys__archive_load
  version=$(next_version)
  mkdir -p "$ROOT/keyring/build"
  export_keys "$ROOT/keyring/build/keys.asc"
  for fmt in rpm deb; do
    (cd "$ROOT" && KEYRING_VERSION=$version nfpm package -f keyring/nfpm.yaml -p "$fmt" \
      -t "$out/files/" > /dev/null) || log__fatal "nfpm failed to build the $fmt keyring"
  done
  write_result "$version" "$out/files" "$out/result.json"
  log__info "keyring: built $KEYRING@$version"
}

[[ $# -eq 1 ]] || log__fatal "usage: keyring.sh <outdir>"
main "$@"
