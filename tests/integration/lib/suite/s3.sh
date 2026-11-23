# shellcheck shell=bash
# The test bucket the distributor publishes to: reading it back over its public HTTPS URL.

[[ -n ${_IT_S3_SH:-} ]] && return 0
_IT_S3_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../settings.sh"
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"

################################################################################
# An object's URL.
# Arguments:
#   Key (e.g. rpm/repodata/repomd.xml).
# Outputs:
#   The URL on stdout.
################################################################################
s3__url() {
  echo "$(settings__get .s3.url)/$1"
}

################################################################################
# Downloads an object.
# Arguments:
#   Key, destination file.
# Returns:
#   0, or 1 when it isn't there.
################################################################################
s3__get() {
  curl -fsS -o "$2" "$(s3__url "$1")" 2> /dev/null
}

################################################################################
# Whether an object exists.
# Arguments:
#   Key.
# Returns:
#   0 when it does, 1 otherwise.
################################################################################
s3__has_object() {
  curl -fsSI -o /dev/null "$(s3__url "$1")" 2> /dev/null
}

################################################################################
# Whether an object is gone.
# Arguments:
#   Key.
# Returns:
#   0 when it is, 1 otherwise.
################################################################################
s3__is_gone() {
  # 403 without listing rights, else 404.
  [[ $(curl -sSI -o /dev/null -w '%{http_code}' "$(s3__url "$1")") == 40[34] ]]
}

################################################################################
# Whether an object is served with this Cache-Control.
# Arguments:
#   Key, the expected header value.
# Returns:
#   0 when it is, 1 otherwise.
################################################################################
s3__has_cache_control() {
  [[ $(curl -fsSI "$(s3__url "$1")" | tr -d '\r' |
    sed -n 's/^[Cc]ache-[Cc]ontrol: //p') == "$2" ]]
}

################################################################################
# HTTPS for apt in a stock Debian image, which has no CA certificates: writes this container's
# CA bundle and an apt config pointing at it, for s3__apt_https_options to mount.
# Arguments:
#   Directory (a path on the host).
# Returns:
#   0, or 1 when they weren't written.
################################################################################
s3__apt_https_write() {
  if ! cp /etc/ssl/certs/ca-certificates.crt "$1/ca.crt" ||
    ! echo 'Acquire::https::CAInfo "/etc/it-ca.crt";' > "$1/ca.conf"; then
    log__error "can't write apt's CA files to $1"
    return 1
  fi
}

################################################################################
# Engine options mounting s3__apt_https_write's files.
# Arguments:
#   Directory.
# Outputs:
#   Options on stdout, one per line.
################################################################################
s3__apt_https_options() {
  printf '%s\n' -v "$1/ca.crt:/etc/it-ca.crt:ro" -v "$1/ca.conf:/etc/apt/apt.conf.d/99it-ca:ro"
}

################################################################################
# A published package's key on the bucket, as prune computes it.
# Arguments:
#   Format (rpm or deb), package name, file name.
# Outputs:
#   The key on stdout.
################################################################################
s3__package_key() {
  if [[ $1 == rpm ]]; then echo "rpm/packages/$3"; else echo "deb/pool/main/${2:0:1}/$2/$3"; fi
}

################################################################################
# A release's package keys on the bucket, from state.
# Arguments:
#   Repo path (owner/name), tag.
# Outputs:
#   Keys on stdout, one per line.
################################################################################
s3__release_keys() {
  local format name file
  state__json | jq -r --arg k "$1@$2" '.[$k].packages[] | [.format, .name, .filename] | @tsv' |
    while IFS=$'\t' read -r format name file; do s3__package_key "$format" "$name" "$file"; done
}

################################################################################
# Downloads a release's packages from the bucket, each under its key (rpm/..., deb/...).
# Arguments:
#   Repo path (owner/name, or openchami-keyring), tag, destination directory.
# Returns:
#   0, or 1 when a download failed.
################################################################################
s3__release_download() {
  local key
  for key in $(s3__release_keys "$1" "$2"); do
    mkdir -p "$3/$(dirname "$key")"
    if ! s3__get "$key" "$3/$key"; then
      log__error "can't download $key from the bucket"
      return 1
    fi
  done
}
