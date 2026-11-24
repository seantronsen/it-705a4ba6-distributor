#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# Publish one format. Only adds: no retention, no denied keys.
#
#   publish.sh <rpm|deb> <outdir> [admit-dir...]
#
# Takes the admitted packages of that format from each admit dir's result.json, signs the rpms,
# writes the packages to the publish target, then merges them into the repository metadata.
# Writes <outdir>/delta-<format>.json for record.
#
# Environment: ARCHIVE_GPG_KEY, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (required);
#   ARCHIVE_GPG_PASSPHRASE (optional).
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/keys.sh"
source "$(dirname "$0")/lib/package.sh"
source "$(dirname "$0")/lib/metadata.sh"
source "$(dirname "$0")/lib/target.sh"

################################################################################
# A format's packages from the admit dirs that were admitted, each with its release key and its
# file's path.
# Arguments:
#   <rpm|deb> [admit dir...]
# Outputs:
#   The packages as a JSON array on stdout.
################################################################################
admitted_packages() {
  local fmt="$1" d new='[]'
  shift
  for d in "$@"; do
    d="$(cd "${d}" && pwd)"
    new="$(jq -c --arg fmt "${fmt}" --arg d "${d}" --slurpfile r "${d}/result.json" '. + [$r[0]
      | select(.status == "published") | .key as $k
      | .packages[] | select(.format == $fmt) | . + {release: $k, path: "\($d)/\(.path)"}]' \
      <<< "${new}")"
  done
  echo "${new}"
}

################################################################################
# Copies the new packages into the staging dir at their target paths, signing the rpms.
# Arguments:
#   <rpm|deb> <new packages (admitted_packages)> <staging dir>
################################################################################
stage_packages() {
  local fmt="$1" new="$2" dir="$3" name filename path rel dest
  while IFS=$'\t' read -r name filename path; do
    rel="$(package__target_path "${fmt}" "${name}" "${filename}")"
    dest="${dir}/${rel#*/}"
    mkdir -p "$(dirname "${dest}")"
    cp "${path}" "${dest}"
    if [[ "${fmt}" == rpm ]]; then keys__rpm_sign "${dest}"; fi
  done < <(jq -r '.[] | [.name, .filename, .path] | @tsv' <<< "${new}")
}

################################################################################
# Uploads the staged packages to the target, in parallel (package names are unique).
# Arguments:
#   <rpm|deb> <new packages (admitted_packages)> <staging dir>
################################################################################
upload_packages() {
  local fmt="$1" new="$2" dir="$3" name filename rel
  jq -r '.[] | [.name, .filename] | @tsv' <<< "${new}" | while IFS=$'\t' read -r name filename; do
    rel="$(package__target_path "${fmt}" "${name}" "${filename}")"
    printf '%s\0%s\0' "${dir}/${rel#*/}" "${rel}"
  done | xargs -0 -n 2 -P 8 bash -c 'source "$0"; target__file_put "$1" "$2"' \
    "${ROOT}/scripts/lib/target.sh"
}

################################################################################
# Writes the delta for record: each new package published, rpms with the archive key that
# signed them (signed_with), so rekey knows what to re-sign.
# Globals:
#   ARCHIVE_FPR (keys__archive_load)
# Arguments:
#   <rpm|deb> <delta file> <new packages (admitted_packages)>
################################################################################
write_publish_delta() {
  jq -n --arg fmt "$1" --arg fpr "${ARCHIVE_FPR}" --argjson new "$3" '{format: $fmt, patches: [
    $new[] | {release, filename, status: "published"}
    + (if $fmt == "rpm" then {signed_with: $fpr} else {} end)]}' > "$2"
}

################################################################################
# Publishes one format: writes the delta (rpms record the archive key that signed them, so rekey
# knows what to re-sign), then the packages, then the metadata merging them in, so metadata never
# points at a missing file.
# Arguments:
#   <rpm|deb> <outdir> [admit dir...]
################################################################################
main() {
  local fmt="$1" out delta new work meta
  base__env_require ARCHIVE_GPG_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  mkdir -p "$2"
  out="$(cd "$2" && pwd)"
  delta="${out}/delta-${fmt}.json"
  shift 2
  new="$(admitted_packages "${fmt}" "$@")"
  if [[ "$(jq length <<< "${new}")" -eq 0 ]]; then
    jq -n --arg fmt "${fmt}" '{format: $fmt, patches: []}' > "${delta}"
    log__info "publish ${fmt}: nothing new"
    return
  fi
  log__info "publish ${fmt}: $(jq length <<< "${new}") new"

  keys__archive_load
  write_publish_delta "${fmt}" "${delta}" "${new}"
  work="$(mktemp -d)"
  # A retried publish replaces the new packages' existing entries instead of duplicating them.
  metadata__excludes "${fmt}" "${new}" > "${work}/excludes"
  stage_packages "${fmt}" "${new}" "${work}/new"
  meta="$(metadata__build "${fmt}" "${work}" "${work}/new" "${work}/excludes")"
  upload_packages "${fmt}" "${new}" "${work}/new"
  metadata__write "${fmt}" "${meta}"
  keys__publish
  log__info "publish ${fmt}: done ($(target__url))"
}

[[ "$#" -ge 2 ]] || log__fatal "usage: publish.sh <rpm|deb> <outdir> [admit-dir...]"
[[ "$1" == rpm || "$1" == deb ]] || log__fatal "unknown format: $1"
main "$@"
