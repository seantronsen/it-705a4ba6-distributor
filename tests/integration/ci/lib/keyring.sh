# shellcheck shell=bash
# The openchami-keyring packages the keyring workflow publishes: finding them in downloaded
# repositories (poll__download_published) and reading the keys they install.

[[ -n ${_IT_KEYRING_SH:-} ]] && return 0
_IT_KEYRING_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/keys.sh"

################################################################################
# A keyring package in downloaded repositories.
# Arguments:
#   Directory, format (rpm or deb), version.
# Outputs:
#   The file's path on stdout (nothing when it isn't there).
################################################################################
keyring__package() {
  local pattern
  if [[ $2 == rpm ]]; then pattern="openchami-keyring-$3-*.rpm"; else
    pattern="openchami-keyring_$3-*.deb"
  fi
  find "$1/$2" -name "$pattern" | head -n 1
}

################################################################################
# The primary key fingerprints the deb installs as /usr/share/keyrings/openchami-keyring.asc.
# Arguments:
#   The deb.
# Outputs:
#   Fingerprints on stdout, sorted, one per line.
################################################################################
keyring__deb_fprs() {
  dpkg-deb --fsys-tarfile "$1" | tar -xO ./usr/share/keyrings/openchami-keyring.asc |
    keys__gpg --batch --show-keys --with-colons 2> /dev/null |
    awk -F: '$1 == "pub" {p = 1; next} p && $1 == "fpr" {print $10; p = 0}' | sort
}

################################################################################
# Whether the rpm installs /etc/pki/rpm-gpg/RPM-GPG-KEY-openchami. (Its content is checked by
# the distro tests, which install it.)
# Arguments:
#   The rpm.
# Returns:
#   0 when it does, 1 otherwise.
################################################################################
keyring__rpm_has_key() {
  rpm -qlp "$1" 2> /dev/null | grep -qx /etc/pki/rpm-gpg/RPM-GPG-KEY-openchami
}

################################################################################
# Checks both keyring packages of a version in downloaded repositories: the rpm installs the
# key file, the deb exactly these keys. Reports every problem.
# Arguments:
#   Directory, version, then the expected fingerprints.
# Returns:
#   0 when both match, 1 otherwise.
################################################################################
keyring__check() {
  local dir=$1 version=$2 rpm deb failed=false
  shift 2
  rpm=$(keyring__package "$dir" rpm "$version")
  deb=$(keyring__package "$dir" deb "$version")
  if [[ -z $rpm ]] || ! keyring__rpm_has_key "$rpm"; then
    log__error "no keyring rpm $version installing the key file in $dir"
    failed=true
  fi
  if [[ -z $deb ]]; then
    log__error "no keyring deb $version in $dir"
    failed=true
  elif [[ $(keyring__deb_fprs "$deb") != "$(printf '%s\n' "$@" | sort)" ]]; then
    log__error "keyring deb $version carries $(keyring__deb_fprs "$deb" | xargs), not $*"
    failed=true
  fi
  ! $failed
}
