# shellcheck shell=bash
# Package files: their metadata, supported architectures, and paths on the target.

[[ -n ${_LIB_PACKAGE_SH:-} ]] && return 0
_LIB_PACKAGE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

################################################################################
# A package file's metadata. The version is the upstream version: rpm VERSION, or deb Version
# without epoch or revision.
# Arguments:
#   <.rpm or .deb file>
# Outputs:
#   {format, name, version, arch, filename} as JSON on stdout.
################################################################################
package__info() {
  local f=$1 name version arch format
  case $f in
    *.rpm)
      format=rpm
      IFS=$'\t' read -r name version arch < <(rpm -qp --nosignature --nodigest \
        --qf '%{NAME}\t%{VERSION}\t%{ARCH}\n' "$f" 2> /dev/null)
      ;;
    *.deb)
      format=deb
      name=$(dpkg-deb -f "$f" Package)
      version=$(dpkg-deb -f "$f" Version)
      arch=$(dpkg-deb -f "$f" Architecture)
      version=${version#*:}
      [[ $version == *-* ]] && version=${version%-*}
      ;;
    *) log__fatal "not a package: $f" ;;
  esac
  jq -nc --arg format "$format" --arg name "$name" --arg version "$version" --arg arch "$arch" \
    --arg filename "$(basename "$f")" \
    '{format: $format, name: $name, version: $version, arch: $arch, filename: $filename}'
}

################################################################################
# Whether the distributor publishes an architecture.
# Arguments:
#   <format> <arch>
# Returns:
#   0 when it does, 1 otherwise.
################################################################################
package__is_supported_arch() {
  case $1:$2 in
    rpm:x86_64 | rpm:aarch64 | rpm:noarch | deb:amd64 | deb:arm64 | deb:all) return 0 ;;
    *) return 1 ;;
  esac
}

################################################################################
# A package's path on the target.
# Arguments:
#   <format> <name> <filename>
# Outputs:
#   The path on stdout.
################################################################################
package__path() {
  case $1 in
    rpm) echo "rpm/packages/$3" ;;
    deb) echo "deb/pool/main/${2:0:1}/$2/$3" ;;
  esac
}
