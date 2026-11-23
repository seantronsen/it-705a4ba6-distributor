# shellcheck shell=bash
# The publish target: the config's `target.s3` bucket, or else the local directory PUBLISH_DIR.
# Paths are relative to the target's root (e.g. rpm/packages/<file>).

[[ -n ${_LIB_TARGET_SH:-} ]] && return 0
_LIB_TARGET_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

################################################################################
# Checks the target is usable before anything is written.
# Globals:
#   ARCHIVE_GPG_KEY, PUBLISH_DIR
################################################################################
target__init() {
  if target__is_s3; then
    # A throwaway key on a real target would publish packages nobody can verify.
    [[ -n ${ARCHIVE_GPG_KEY:-} ]] || log__fatal "target.s3 is set, so ARCHIVE_GPG_KEY is required"
  else
    mkdir -p "${PUBLISH_DIR:?PUBLISH_DIR is required without target.s3}"
  fi
}

################################################################################
# Whether the target is an S3 bucket.
# Returns:
#   0 for S3, 1 for the local directory.
################################################################################
target__is_s3() {
  config__has .target.s3
}

################################################################################
# The target's location, for logs and the aws CLI.
# Outputs:
#   s3://<bucket>, or the PUBLISH_DIR path, on stdout.
################################################################################
target__url() {
  if target__is_s3; then
    echo "s3://$(config__get .target.s3.bucket)"
  else
    echo "$PUBLISH_DIR"
  fi
}

################################################################################
# The aws CLI, at the bucket's region and endpoint.
# Arguments:
#   aws's arguments.
################################################################################
target__aws() {
  local endpoint=()
  if config__has .target.s3.endpoint; then
    endpoint=(--endpoint-url "$(config__get .target.s3.endpoint)")
  fi
  aws --region "$(config__get .target.s3.region)" "${endpoint[@]}" "$@"
}

################################################################################
# A file's Cache-Control: packages never change; metadata and keys do, so caches (a CDN)
# refetch them after target.s3.metadata-max-age seconds.
# Arguments:
#   <path>
# Outputs:
#   The header value on stdout.
################################################################################
target__cache_control() {
  case $1 in
    rpm/packages/* | deb/pool/*) echo 'public,max-age=31536000,immutable' ;;
    *) echo "public,max-age=$(config__get '.target.s3["metadata-max-age"]'),must-revalidate" ;;
  esac
}

################################################################################
# Downloads a file. Exits on any error but absence, since "absent" makes publish rebuild the
# metadata from scratch. On S3, absence reads as NoSuchKey only with s3:ListBucket (else
# AccessDenied).
# Arguments:
#   <path> <dest>
# Returns:
#   0, or 1 when the file is absent.
################################################################################
target__get() {
  local err
  mkdir -p "$(dirname "$2")"
  if ! target__is_s3; then
    [[ -f $PUBLISH_DIR/$1 ]] || return 1
    cp "$PUBLISH_DIR/$1" "$2"
  elif ! err=$(target__aws s3api get-object --bucket "$(config__get .target.s3.bucket)" \
    --key "$1" "$2" 2>&1 > /dev/null); then
    [[ $err == *NoSuchKey* ]] && return 1
    log__fatal "can't read $(target__url)/$1: $err"
  fi
}

################################################################################
# Uploads a file, atomically.
# Arguments:
#   <src> <path>
################################################################################
target__put() {
  if target__is_s3; then
    target__aws s3 cp --only-show-errors --cache-control "$(target__cache_control "$2")" "$1" \
      "$(target__url)/$2"
    return
  fi
  local dest=$PUBLISH_DIR/$2
  mkdir -p "$(dirname "$dest")"
  cp "$1" "$dest.tmp.$$"
  mv -f "$dest.tmp.$$" "$dest"
}

################################################################################
# Deletes a file.
# Arguments:
#   <path>
################################################################################
target__rm() {
  if target__is_s3; then
    target__aws s3 rm --only-show-errors "$(target__url)/$1"
  else
    rm -f "$PUBLISH_DIR/$1"
  fi
}

################################################################################
# The files directly in a directory.
# Arguments:
#   <dir>
# Outputs:
#   Their names on stdout, one per line.
################################################################################
target__ls() {
  if target__is_s3; then
    target__aws s3api list-objects-v2 --bucket "$(config__get .target.s3.bucket)" --prefix "$1/" \
      --delimiter / --output json \
      | jq -r --arg p "$1/" '(.Contents // [])[].Key | ltrimstr($p)'
    return
  fi
  [[ -d $PUBLISH_DIR/$1 ]] || return 0
  find "$PUBLISH_DIR/$1" -maxdepth 1 -type f ! -name '*.tmp.*' -printf '%f\n'
}

################################################################################
# Every file under a directory.
# Arguments:
#   <dir>
# Outputs:
#   Their paths on stdout, one per line.
################################################################################
target__find() {
  if target__is_s3; then
    target__aws s3api list-objects-v2 --bucket "$(config__get .target.s3.bucket)" --prefix "$1/" \
      --output json \
      | jq -r '(.Contents // [])[].Key'
    return
  fi
  [[ -d $PUBLISH_DIR/$1 ]] || return 0
  (cd "$PUBLISH_DIR" && find "$1" -type f ! -name '*.tmp.*')
}
