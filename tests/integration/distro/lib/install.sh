# shellcheck shell=bash
# Installing openchami-keyring with each distro's package manager, then trusting the published
# repository through the key it installed instead of the published key file. Same repository
# layout and base URLs as target.sh.

[[ -n ${_IT_INSTALL_SH:-} ]] && return 0
_IT_INSTALL_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/engine.sh"

################################################################################
# dnf: installs the keyring (trusting keys/archive.asc), then refreshes the repository with
# only the installed key.
# Arguments:
#   Image, the published files (a path on the host), base URL, then extra engine options.
# Returns:
#   0 when both steps pass, 1 otherwise.
################################################################################
install__keyring_dnf() {
  local image=$1 dir=$2 base=$3
  shift 3
  if ! engine__run -i -v "$dir:/repo:ro" -e "BASE=$base" "$@" "$image" bash -s << 'EOF'; then
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
    log__error "dnf on $image: the keyring from $base didn't install or verify the repository"
    return 1
  fi
}

################################################################################
# apt: installs the keyring (trusting keys/archive.asc), then updates with only the installed
# keyring as signed-by.
# Arguments:
#   Image, the published files (a path on the host), base URL, then extra engine options.
# Returns:
#   0 when both steps pass, 1 otherwise.
################################################################################
install__keyring_apt() {
  local image=$1 dir=$2 base=$3
  shift 3
  if ! engine__run -i -v "$dir:/repo:ro" -e "BASE=$base" "$@" "$image" bash -s << 'EOF'; then
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
    log__error "apt on $image: the keyring from $base didn't install or verify the repository"
    return 1
  fi
}
