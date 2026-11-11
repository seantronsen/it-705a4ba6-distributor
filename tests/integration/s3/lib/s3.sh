# shellcheck shell=bash
# The test bucket: the distributor config that publishes to it, and reading it back over its
# public HTTPS URL (objects only; tests have no credentials).

[[ -n ${_IT_S3_SH:-} ]] && return 0
_IT_S3_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/settings.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/distributor.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/state.sh"

################################################################################
# Installs curl in the tools container.
# Returns:
#   0, or 1 when apt failed.
################################################################################
s3__install_tools() {
  if ! apt-get install -y -qq --no-install-recommends curl > /dev/null 2>&1; then
    log__error "apt couldn't install curl"
    return 1
  fi
}

################################################################################
# The metadata max age the tests configure, in seconds.
# Outputs:
#   Seconds on stdout.
################################################################################
s3__max_age() { echo 60; }

################################################################################
# The default config, publishing to the test bucket.
# Outputs:
#   config/repos.yaml content on stdout.
################################################################################
s3__config() {
  distributor__default_config
  cat << EOF
target:
  s3:
    bucket: $(settings__get .s3.bucket)
    region: $(settings__get .s3.region)
    metadata-max-age: $(s3__max_age)
EOF
}

################################################################################
# Publishes to the test bucket from now on: pushes s3__config and waits for its poll, whose
# prune also removes whatever earlier tests left there (state no longer lists it).
# Outputs:
#   The poll's run id on stdout.
# Returns:
#   0, or 1 when the push or its poll failed.
################################################################################
s3__use() {
  s3__config | distributor__push_config
}

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
s3__exists() {
  curl -fsSI -o /dev/null "$(s3__url "$1")" 2> /dev/null
}

################################################################################
# Whether an object is gone (403 without listing rights, else 404).
# Arguments:
#   Key.
# Returns:
#   0 when it is, 1 otherwise.
################################################################################
s3__gone() {
  [[ $(curl -sSI -o /dev/null -w '%{http_code}' "$(s3__url "$1")") == 40[34] ]]
}

################################################################################
# Whether an object is served with this Cache-Control.
# Arguments:
#   Key, the expected header value.
# Returns:
#   0 when it is, 1 otherwise.
################################################################################
s3__cache_control_is() {
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
s3__apt_https() {
  if ! cp /etc/ssl/certs/ca-certificates.crt "$1/ca.crt" ||
    ! echo 'Acquire::https::CAInfo "/etc/it-ca.crt";' > "$1/ca.conf"; then
    log__error "can't write apt's CA files to $1"
    return 1
  fi
}

################################################################################
# Engine options mounting s3__apt_https's files.
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
#   owner/name, tag.
# Outputs:
#   Keys on stdout, one per line.
################################################################################
s3__release_keys() {
  local format name file
  state__get | jq -r --arg k "$1@$2" '.[$k].packages[] | [.format, .name, .filename] | @tsv' |
    while IFS=$'\t' read -r format name file; do s3__package_key "$format" "$name" "$file"; done
}
