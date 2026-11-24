# SPDX-FileCopyrightText: © 2026 OpenCHAMI a Series of LF Projects, LLC
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
# Each distro's own package manager installing from the published repository, in a clean sibling
# container: a package, checking signatures against the archive key from /repo/keys/archive.asc
# (the directory mounted at /repo); or openchami-keyring, then trusting the repository through
# the key it installed instead. The base URL is the bucket's.

[[ -n "${_IT_INSTALL_SH:-}" ]] && return 0
_IT_INSTALL_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/engine.sh"

################################################################################
# Installs a package with dnf, only the published repository enabled.
# Arguments:
#   Image, the published files' directory, base URL, package, then extra engine options.
# Returns:
#   0 when installed, 1 otherwise.
################################################################################
install__package_dnf() {
  local image="$1" dir="$2" base="$3" package="$4"
  shift 4
  if ! engine__run -i -v "${dir}:/repo:ro" -e "BASE=${base}" -e "PACKAGE=${package}" "$@" \
    "${image}" \
    bash -s << 'EOF'; then
set -euo pipefail
cat > /etc/yum.repos.d/it.repo << REPO
[it]
name=it
baseurl=$BASE/rpm
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///repo/keys/archive.asc
REPO
dnf -y -q --disablerepo='*' --enablerepo=it install "$PACKAGE"
rpm -q "$PACKAGE"
EOF
    log__error "dnf on ${image} couldn't install ${package} from ${base}"
    return 1
  fi
}

################################################################################
# Installs a package with apt, only the published repository configured, signed-by the archive
# key.
# Arguments:
#   Image, the published files' directory, base URL, package, then extra engine options.
# Returns:
#   0 when installed, 1 otherwise.
################################################################################
install__package_apt() {
  local image="$1" dir="$2" base="$3" package="$4"
  shift 4
  if ! engine__run -i -v "${dir}:/repo:ro" -e "BASE=${base}" -e "PACKAGE=${package}" "$@" \
    "${image}" \
    bash -s << 'EOF'; then
set -euo pipefail
install -Dm644 /repo/keys/archive.asc /etc/apt/keyrings/it.asc
echo "deb [signed-by=/etc/apt/keyrings/it.asc] $BASE/deb stable main" > /etc/apt/it.list
apt=(apt-get -o Dir::Etc::sourcelist=/etc/apt/it.list -o Dir::Etc::sourceparts=-)
"${apt[@]}" update -qq
"${apt[@]}" install -y -qq "$PACKAGE"
dpkg -s "$PACKAGE" | grep ^Version
EOF
    log__error "apt on ${image} couldn't install ${package} from ${base}"
    return 1
  fi
}

################################################################################
# dnf: installs the keyring (trusting keys/archive.asc), then refreshes the repository with
# only the installed key.
# Arguments:
#   Image, the published files' directory, base URL, then extra engine options.
# Returns:
#   0 when both steps pass, 1 otherwise.
################################################################################
install__keyring_dnf() {
  local image="$1" dir="$2" base="$3"
  shift 3
  if ! engine__run -i -v "${dir}:/repo:ro" -e "BASE=${base}" "$@" "${image}" bash -s << 'EOF'; then
set -euo pipefail
# dnf skips a repository that fails verification, and succeeds, unless told otherwise.
repo() { # <id> <gpgkey>
  printf '[%s]\nname=%s\nbaseurl=%s/rpm\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=%s\n%s\n' \
    "$1" "$1" "$BASE" "$2" skip_if_unavailable=0 > "/etc/yum.repos.d/$1.repo"
}
repo it file:///repo/keys/archive.asc
dnf -y -q --disablerepo='*' --enablerepo=it install openchami-keyring
# Forget the bootstrap key, imported into rpm's database, so only the installed file is trusted.
rm /etc/yum.repos.d/it.repo
rpm -e --allmatches gpg-pubkey
dnf clean all > /dev/null
repo it-keyring file:///etc/pki/rpm-gpg/RPM-GPG-KEY-openchami
dnf -y -q --disablerepo='*' --enablerepo=it-keyring makecache
EOF
    log__error "dnf on ${image}: the keyring from ${base} didn't install or verify the repository"
    return 1
  fi
}

################################################################################
# apt: installs the keyring (trusting keys/archive.asc), then updates with only the installed
# keyring as signed-by.
# Arguments:
#   Image, the published files' directory, base URL, then extra engine options.
# Returns:
#   0 when both steps pass, 1 otherwise.
################################################################################
install__keyring_apt() {
  local image="$1" dir="$2" base="$3"
  shift 3
  if ! engine__run -i -v "${dir}:/repo:ro" -e "BASE=${base}" "$@" "${image}" bash -s << 'EOF'; then
set -euo pipefail
apt=(apt-get -o Dir::Etc::sourcelist=/etc/apt/it.list -o Dir::Etc::sourceparts=-)
install -Dm644 /repo/keys/archive.asc /etc/apt/keyrings/it.asc
echo "deb [signed-by=/etc/apt/keyrings/it.asc] $BASE/deb stable main" > /etc/apt/it.list
"${apt[@]}" update -qq
"${apt[@]}" install -y -qq openchami-keyring
rm /etc/apt/keyrings/it.asc
echo "deb [signed-by=/usr/share/keyrings/openchami-keyring.asc] $BASE/deb stable main" \
  > /etc/apt/it.list
# apt only warns when verification fails, unless told otherwise.
"${apt[@]}" update -qq --error-on=any
EOF
    log__error "apt on ${image}: the keyring from ${base} didn't install or verify the repository"
    return 1
  fi
}
