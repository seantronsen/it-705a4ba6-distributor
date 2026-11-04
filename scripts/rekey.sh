#!/usr/bin/env bash
# Re-sign a format's published repository with the current archive key, after a key switch.
#
#   rekey.sh <rpm|deb> <outdir>
#
# rpm: re-signs every published rpm whose signed_with isn't the current key, BATCH at a time,
# then its metadata; writes <outdir>/rekey-rpm.json after each batch, so record keeps the
# progress after a failure or timeout and a rerun resumes from state. deb: re-signs Release (debs
# carry no signature). Both republish keys/.
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/lib-repo.sh"

BATCH=50

# Published rpms not signed with the current key, as [{release, filename}].
rpms_to_resign() {
  state_json | jql -c --arg fpr "$ARCHIVE_FPR" 'include "lib";
    published_packages | map(select(.format == "rpm" and .signed_with != $fpr) | {release, filename})'
}

# Downloads, re-signs, and re-uploads one batch, then rewrites the metadata over it.
resign_batch() { # <batch json> <work dir>
  local dir=$2 f meta
  mkdir -p "$dir/new/packages"
  jq -r '.[].filename' <<< "$1" > "$dir/excludes"
  while IFS= read -r f; do
    target_get "rpm/packages/$f" "$dir/new/packages/$f" || die "rpm/packages/$f is in state but not on the target"
    rpm_resign "$dir/new/packages/$f"
  done < "$dir/excludes"
  meta=$(rpm_metadata "$dir/meta" "$dir/new" "$dir/excludes")
  while IFS= read -r f; do target_put "$dir/new/packages/$f" "rpm/packages/$f"; done < "$dir/excludes"
  rpm_metadata_write "$meta"
}

rekey_rpm() { # <delta file>
  local todo total i batch
  todo=$(rpms_to_resign)
  total=$(jq length <<< "$todo")
  log "rekey rpm: $total package(s) to re-sign with $ARCHIVE_FPR"
  for ((i = 0; i < total; i += BATCH)); do
    batch=$(jq -c --argjson i "$i" --argjson n "$BATCH" '.[$i:$i + $n]' <<< "$todo")
    resign_batch "$batch" "$work/batch-$i"
    jq --argjson b "$batch" --arg fpr "$ARCHIVE_FPR" '.patches += [$b[] + {signed_with: $fpr}]' \
      "$1" > "$1.tmp" && mv "$1.tmp" "$1"
    log "rekey rpm: $((i + $(jq length <<< "$batch")))/$total re-signed"
  done
  # Nothing to re-sign: still re-sign repomd.xml, which no batch rewrote.
  if [[ $total -eq 0 ]] && target_get rpm/repodata/repomd.xml "$work/repomd.xml"; then
    gpg --batch --armor --detach-sign -o "$work/repomd.xml.asc" "$work/repomd.xml"
    target_put "$work/repomd.xml.asc" rpm/repodata/repomd.xml.asc
  fi
}

rekey_deb() {
  target_get "deb/dists/$SUITE/Release" "$work/dist/Release" || return 0
  apt_sign "$work/dist"
  target_put "$work/dist/Release.gpg" "deb/dists/$SUITE/Release.gpg"
  target_put "$work/dist/InRelease" "deb/dists/$SUITE/InRelease"
}

[[ $# -eq 2 && ($1 == rpm || $1 == deb) ]] || die "usage: rekey.sh <rpm|deb> <outdir>"
fmt=$1
mkdir -p "$2"
delta=$(cd "$2" && pwd)/rekey-$fmt.json
jq -n --arg fmt "$fmt" '{format: $fmt, patches: []}' > "$delta"

target_init
archive_key_init
work=$(mktemp -d)
if [[ $fmt == rpm ]]; then rekey_rpm "$delta"; else rekey_deb; fi
keys_write
log "rekey $fmt: done ($TARGET)"
