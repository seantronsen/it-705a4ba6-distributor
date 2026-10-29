# shellcheck shell=bash
# Installing a package from the distributor's published repositories the way users do, with
# signatures checked: dnf on Fedora and apt on Debian, each in a clean sibling container.

[[ -n ${_IT_INSTALL_SH:-} ]] && return 0
_IT_INSTALL_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/engine.sh"

#######################################
# Installs a package with dnf from a published rpm repository, only that repository enabled,
# with package and repository signatures checked against the repository's archive key.
# Arguments:
#   The downloaded rpm target (rpm/ and keys/; a host path, under suite__share_dir),
#   package name.
# Returns:
#   0 when installed, 1 otherwise.
#######################################
install__dnf() {
  engine__run -i -v "$1:/repo:ro" -e "PKG=$2" "$(suite__tools_image)" bash -s << 'EOF' ||
cat > /etc/yum.repos.d/it.repo << REPO
[it]
name=it
baseurl=file:///repo/rpm
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///repo/keys/archive.asc
REPO
dnf -y -q --disablerepo='*' --enablerepo=it install "$PKG" && rpm -q "$PKG"
EOF
    log__error "dnf couldn't install $2 from $1"
}

#######################################
# Installs a package with apt from a published deb repository, only that source configured,
# signed-by the repository's archive key.
# Arguments:
#   The downloaded deb target (deb/ and keys/; a host path, under suite__share_dir),
#   package name.
# Returns:
#   0 when installed, 1 otherwise.
#######################################
install__apt() {
  engine__run -i -v "$1:/repo:ro" -e "PKG=$2" "$(suite__debian_image)" bash -s << 'EOF' ||
install -Dm644 /repo/keys/archive.asc /etc/apt/keyrings/it.asc
echo 'deb [signed-by=/etc/apt/keyrings/it.asc] file:/repo/deb stable main' > /etc/apt/it.list
apt=(apt-get -o Dir::Etc::sourcelist=/etc/apt/it.list -o Dir::Etc::sourceparts=-)
"${apt[@]}" update -qq && "${apt[@]}" install -y -qq "$PKG" && dpkg -s "$PKG" | grep ^Version
EOF
    log__error "apt couldn't install $2 from $1"
}
