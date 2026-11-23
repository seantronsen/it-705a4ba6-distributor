# shellcheck shell=bash
# Repository metadata updates for publish, prune, and rekey, without downloading old packages.
# Needs keys__archive_load first.

[[ -n "${_LIB_METADATA_SH:-}" ]] && return 0
_LIB_METADATA_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/package.sh"
source "$(dirname "${BASH_SOURCE[0]}")/target.sh"

RPM_COMPRESS=(--general-compress-type=gz --no-database --quiet)

################################################################################
# The deb architectures with their own Packages index: the config's, but `all`, whose packages
# every index lists.
# Outputs:
#   The architectures on stdout, one per line.
################################################################################
metadata__deb_architectures() {
  config__get .architectures.deb | jq -r '.[] | select(. != "all")'
}

################################################################################
# Rebuilds the rpm metadata: starts from the target's repodata, drops the entries for the files
# listed in <excludes> (one filename per line), merges in <new>/packages/*.rpm (already signed),
# and signs repomd.xml.
# Arguments:
#   <work dir> <new dir> <excludes file>
# Outputs:
#   The directory holding the new repodata/ on stdout.
################################################################################
metadata__rpm_build() {
  local work="$1" new="$2" excludes="$3" old="$1/rpm-old" have_old=false have_new=false href f
  mkdir -p "${old}/repodata" "${new}/packages"
  if target__file_get rpm/repodata/repomd.xml "${old}/repodata/repomd.xml"; then
    have_old=true
    while IFS= read -r href; do
      target__file_get "rpm/${href}" "${old}/${href}" \
        || log__fatal "rpm/${href} is referenced by repomd.xml but missing"
    done < <(grep -o 'href="repodata/[^"]*"' "${old}/repodata/repomd.xml" | cut -d'"' -f2)
    if [[ -s "${excludes}" ]]; then
      local args=()
      while IFS= read -r f; do args+=(--excludes "packages/${f}"); done < "${excludes}"
      createrepo_c "${RPM_COMPRESS[@]}" --update --skip-stat --recycle-pkglist "${args[@]}" "${old}"
    fi
  fi
  compgen -G "${new}/packages/*.rpm" > /dev/null && have_new=true
  [[ "${have_new}" == true ]] && createrepo_c "${RPM_COMPRESS[@]}" "${new}"

  local result
  if [[ "${have_old}" == true && "${have_new}" == true ]]; then
    mergerepo_c --all --omit-baseurl --no-database --compress-type=gz \
      --repo "${old}" --repo "${new}" -o "${work}/rpm-merged" > /dev/null
    result="${work}/rpm-merged"
  elif [[ "${have_old}" == true ]]; then
    result="${old}"
  elif [[ "${have_new}" == true ]]; then
    result="${new}"
  else
    createrepo_c "${RPM_COMPRESS[@]}" "${new}"
    result="${new}"
  fi
  metadata__rpm_repomd_sign "${result}/repodata"
  echo "${result}"
}

################################################################################
# Signs repomd.xml with the archive key: repomd.xml.asc beside it, replacing any old one.
# Arguments:
#   <dir holding repomd.xml>
################################################################################
metadata__rpm_repomd_sign() {
  rm -f "$1/repomd.xml.asc"
  gpg --batch --armor --detach-sign -o "$1/repomd.xml.asc" "$1/repomd.xml"
}

################################################################################
# Writes the rpm repodata to the target: data files first, then the signature, then repomd.xml
# last (it points at everything else), then removes repodata files it no longer references.
# The signature and repomd.xml can't change together, so between the two writes dnf fails
# closed on a mismatch instead of reading a repomd.xml that points at missing files.
# Arguments:
#   <dir holding repodata/>
################################################################################
metadata__rpm_write() {
  local dir="$1" f
  for f in "${dir}"/repodata/*; do
    case "${f##*/}" in
      repomd.xml | repomd.xml.asc) ;;
      *) target__file_put "${f}" "rpm/repodata/${f##*/}" ;;
    esac
  done
  target__file_put "${dir}/repodata/repomd.xml.asc" rpm/repodata/repomd.xml.asc
  target__file_put "${dir}/repodata/repomd.xml" rpm/repodata/repomd.xml
  for f in $(target__file_list rpm/repodata); do
    [[ -e "${dir}/repodata/${f}" ]] || target__file_delete "rpm/repodata/${f}"
  done
}

################################################################################
# Filters a Packages file: keeps the stanzas whose Filename isn't in the excludes file (pool
# paths) and, when an arch is given, whose Architecture is that arch or all.
# Arguments:
#   <excludes file> <arch, or "">
# Inputs:
#   The Packages file on stdin.
# Outputs:
#   The kept stanzas on stdout.
################################################################################
metadata__apt_packages_filter() {
  awk -v ex="$1" -v arch="$2" '
    BEGIN { while ((getline l < ex) > 0) skip[l] = 1; RS = ""; ORS = "\n\n" }
    {
      n = split($0, L, "\n"); f = ""; a = ""
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^Filename: /) f = substr(L[i], 11)
        if (L[i] ~ /^Architecture: /) a = substr(L[i], 15)
      }
      if (!(f in skip) && (arch == "" || a == arch || a == "all")) print
    }'
}

################################################################################
# Rebuilds the apt metadata: per architecture, the target's Packages minus <excludes> (pool
# paths, one per line) plus the stanzas for <new>/pool/**.deb; then Release, InRelease, and
# Release.gpg.
# Arguments:
#   <work dir> <new dir> <excludes file>
# Outputs:
#   The directory holding the new dists/ on stdout.
################################################################################
metadata__apt_build() {
  local work="$1" new="$2" excludes="$3" out="$1/apt-out" arch
  local dist="${out}/dists/${SUITE}"
  mkdir -p "${new}/pool"
  (cd "${new}" && apt-ftparchive packages pool 2> /dev/null) > "${work}/new.Packages"
  for arch in $(metadata__deb_architectures); do
    local bin="${dist}/main/binary-${arch}"
    mkdir -p "${bin}"
    target__file_get "deb/dists/${SUITE}/main/binary-${arch}/Packages" \
      "${work}/old.Packages.${arch}" \
      || : > "${work}/old.Packages.${arch}"
    {
      metadata__apt_packages_filter "${excludes}" "" < "${work}/old.Packages.${arch}"
      metadata__apt_packages_filter /dev/null "${arch}" < "${work}/new.Packages"
    } > "${bin}/Packages"
    gzip -9nc "${bin}/Packages" > "${bin}/Packages.gz"
  done
  (cd "${out}" && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=OpenCHAMI \
    -o APT::FTPArchive::Release::Label=OpenCHAMI \
    -o APT::FTPArchive::Release::Suite="${SUITE}" \
    -o APT::FTPArchive::Release::Codename="${SUITE}" \
    -o APT::FTPArchive::Release::Architectures="$(metadata__deb_architectures | xargs)" \
    -o APT::FTPArchive::Release::Components=main \
    release "dists/${SUITE}") > "${work}/Release"
  mv "${work}/Release" "${dist}/Release"
  metadata__apt_release_sign "${dist}"
  echo "${out}"
}

################################################################################
# Signs a Release file with the archive key: InRelease and Release.gpg beside it.
# Arguments:
#   <dist dir holding Release>
################################################################################
metadata__apt_release_sign() {
  rm -f "$1/InRelease" "$1/Release.gpg"
  gpg --batch --clearsign -o "$1/InRelease" "$1/Release"
  gpg --batch --armor --detach-sign -o "$1/Release.gpg" "$1/Release"
}

################################################################################
# Writes the apt metadata: Packages files first, then Release, Release.gpg, and InRelease.
# Arguments:
#   <dir holding dists/>
################################################################################
metadata__apt_write() {
  local dist="$1/dists/${SUITE}" arch f
  for arch in $(metadata__deb_architectures); do
    for f in Packages Packages.gz; do
      target__file_put "${dist}/main/binary-${arch}/${f}" \
        "deb/dists/${SUITE}/main/binary-${arch}/${f}"
    done
  done
  for f in Release Release.gpg InRelease; do
    target__file_put "${dist}/${f}" "deb/dists/${SUITE}/${f}"
  done
}

################################################################################
# The files to leave out of the target's metadata when rebuilding it: rpm file names, or deb
# paths under deb/.
# Arguments:
#   <rpm|deb> <packages, as JSON [{name, filename}]> [target path]...
# Outputs:
#   The files on stdout, one per line.
################################################################################
metadata__excludes() {
  local fmt="$1" packages="$2" name filename path
  shift 2
  while IFS=$'\t' read -r name filename; do
    if [[ "${fmt}" == rpm ]]; then
      echo "${filename}"
    else
      path="$(package__target_path deb "${name}" "${filename}")"
      echo "${path#deb/}"
    fi
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "${packages}")
  for path in "$@"; do
    if [[ "${fmt}" == rpm ]]; then echo "${path##*/}"; else echo "${path#deb/}"; fi
  done
}

################################################################################
# Rebuilds a format's metadata (metadata__rpm_build or metadata__apt_build).
# Arguments:
#   <rpm|deb> <work dir> <new dir> <excludes file>
# Outputs:
#   The directory holding the new metadata on stdout.
################################################################################
metadata__build() {
  local fmt="$1"
  shift
  if [[ "${fmt}" == rpm ]]; then metadata__rpm_build "$@"; else metadata__apt_build "$@"; fi
}

################################################################################
# Writes a format's rebuilt metadata to the target (metadata__rpm_write or metadata__apt_write).
# Arguments:
#   <rpm|deb> <metadata dir (metadata__build)>
################################################################################
metadata__write() {
  if [[ "$1" == rpm ]]; then metadata__rpm_write "$2"; else metadata__apt_write "$2"; fi
}
