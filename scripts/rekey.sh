#!/usr/bin/env bash
# Re-sign a format's published repository with the current archive key, after a key switch.
#
#   rekey.sh <rpm|deb> <outdir>
#
# rpm: re-signs every published rpm whose signed_with isn't the current key, BATCH at a time,
# then its metadata; writes <outdir>/rekey-rpm.json after each batch, so record keeps the
# progress after a failure or timeout and a rerun resumes from state. deb: re-signs Release (debs
# carry no signature). Both republish keys/.
#
# Environment: ARCHIVE_GPG_KEY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (required);
#   ARCHIVE_GPG_PASSPHRASE (optional).
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/keys.sh"
source "$(dirname "$0")/lib/metadata.sh"
source "$(dirname "$0")/lib/state.sh"
source "$(dirname "$0")/lib/target.sh"

BATCH=50

################################################################################
# The published rpms not signed with the current archive key.
# Globals:
#   ARCHIVE_FPR (keys__archive_load)
# Outputs:
#   [{release, filename}] as JSON on stdout.
################################################################################
rpms_not_signed_with_archive_key() {
  state__json | base__jq -c --arg fpr "${ARCHIVE_FPR}" 'import "state" as state;
    state::published_packages
    | map(select(.format == "rpm" and .signed_with != $fpr) | {release, filename})'
}

################################################################################
# Downloads, re-signs, and re-uploads one batch, then rewrites the metadata over it.
# Arguments:
#   <batch json> <work dir>
################################################################################
resign_rpm_batch() {
  local dir="$2" f meta
  mkdir -p "${dir}/new/packages"
  jq -r '.[].filename' <<< "$1" > "${dir}/excludes"
  while IFS= read -r f; do
    target__file_get "rpm/packages/${f}" "${dir}/new/packages/${f}" \
      || log__fatal "rpm/packages/${f} is in state but not on the target"
    keys__rpm_resign "${dir}/new/packages/${f}"
  done < "${dir}/excludes"
  meta="$(metadata__rpm_build "${dir}/meta" "${dir}/new" "${dir}/excludes")"
  while IFS= read -r f; do
    target__file_put "${dir}/new/packages/${f}" "rpm/packages/${f}"
  done < "${dir}/excludes"
  metadata__rpm_write "${meta}"
}

################################################################################
# Re-signs the rpms BATCH at a time, recording each batch in the delta as it lands; with none
# to re-sign, re-signs repomd.xml alone.
# Arguments:
#   <delta file> <work dir>
################################################################################
resign_rpms() {
  local delta="$1" work="$2" todo total i batch
  todo="$(rpms_not_signed_with_archive_key)"
  total="$(jq length <<< "${todo}")"
  log__info "rekey rpm: ${total} package(s) to re-sign with ${ARCHIVE_FPR}"
  for ((i = 0; i < total; i += BATCH)); do
    batch="$(jq -c --argjson i "${i}" --argjson n "${BATCH}" '.[$i:$i + $n]' <<< "${todo}")"
    resign_rpm_batch "${batch}" "${work}/batch-${i}"
    jq --argjson b "${batch}" --arg fpr "${ARCHIVE_FPR}" \
      '.patches += [$b[] + {signed_with: $fpr}]' \
      "${delta}" > "${delta}.tmp" && mv "${delta}.tmp" "${delta}"
    log__info "rekey rpm: $((i + $(jq length <<< "${batch}")))/${total} re-signed"
  done
  # Nothing to re-sign: still re-sign repomd.xml, which no batch rewrote.
  if [[ "${total}" -eq 0 ]] && target__file_get rpm/repodata/repomd.xml "${work}/repomd.xml"; then
    metadata__rpm_repomd_sign "${work}"
    target__file_put "${work}/repomd.xml.asc" rpm/repodata/repomd.xml.asc
  fi
}

################################################################################
# Re-signs Release (debs carry no signature).
# Arguments:
#   <work dir>
################################################################################
resign_apt_release() {
  local work="$1"
  target__file_get "deb/dists/${SUITE}/Release" "${work}/dist/Release" || return 0
  metadata__apt_release_sign "${work}/dist"
  target__file_put "${work}/dist/Release.gpg" "deb/dists/${SUITE}/Release.gpg"
  target__file_put "${work}/dist/InRelease" "deb/dists/${SUITE}/InRelease"
}

################################################################################
# Re-signs one format, then republishes keys/.
# Arguments:
#   <rpm|deb> <outdir>
################################################################################
main() {
  local fmt="$1" delta work
  base__env_require ARCHIVE_GPG_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  mkdir -p "$2"
  delta="$(cd "$2" && pwd)/rekey-${fmt}.json"
  jq -n --arg fmt "${fmt}" '{format: $fmt, patches: []}' > "${delta}"
  keys__archive_load
  work="$(mktemp -d)"
  if [[ "${fmt}" == rpm ]]; then
    resign_rpms "${delta}" "${work}"
  else
    resign_apt_release "${work}"
  fi
  keys__publish
  log__info "rekey ${fmt}: done ($(target__url))"
}

[[ "$#" -eq 2 && ("$1" == rpm || "$1" == deb) ]] || log__fatal "usage: rekey.sh <rpm|deb> <outdir>"
main "$@"
