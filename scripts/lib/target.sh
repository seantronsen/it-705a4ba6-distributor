# shellcheck shell=bash
# The publish target: the config's `target.s3` bucket. Paths are keys relative to the bucket's
# root (e.g. rpm/packages/<file>).

[[ -n "${_LIB_TARGET_SH:-}" ]] && return 0
_LIB_TARGET_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

################################################################################
# The bucket's URL, for logs and the aws CLI.
# Outputs:
#   s3://<bucket> on stdout.
################################################################################
target__url() {
  echo "s3://$(config__get .target.s3.bucket)"
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
# refetch them after target.s3.metadata_max_age seconds.
# Arguments:
#   <path>
# Outputs:
#   The header value on stdout.
################################################################################
target__cache_control() {
  case "$1" in
    rpm/packages/* | deb/pool/*) echo 'public,max-age=31536000,immutable' ;;
    *) echo "public,max-age=$(config__get .target.s3.metadata_max_age),must-revalidate" ;;
  esac
}

################################################################################
# Downloads a file. Exits on any error but absence, since "absent" makes publish rebuild the
# metadata from scratch. Absence reads as NoSuchKey only with s3:ListBucket (else
# AccessDenied).
# Arguments:
#   <path> <dest>
# Returns:
#   0, or 1 when the file is absent.
################################################################################
target__file_get() {
  local err
  mkdir -p "$(dirname "$2")"
  if ! err="$(target__aws s3api get-object --bucket "$(config__get .target.s3.bucket)" \
    --key "$1" "$2" 2>&1 > /dev/null)"; then
    [[ "${err}" == *NoSuchKey* ]] && return 1
    log__fatal "can't read $(target__url)/$1: ${err}"
  fi
}

################################################################################
# Uploads a file (atomic per object).
# Arguments:
#   <src> <path>
################################################################################
target__file_put() {
  target__aws s3 cp --only-show-errors --cache-control "$(target__cache_control "$2")" "$1" \
    "$(target__url)/$2"
}

################################################################################
# Deletes a file.
# Arguments:
#   <path>
################################################################################
target__file_delete() {
  target__aws s3 rm --only-show-errors "$(target__url)/$1"
}

################################################################################
# The files directly in a directory.
# Arguments:
#   <dir>
# Outputs:
#   Their names on stdout, one per line.
################################################################################
target__file_list() {
  target__aws s3api list-objects-v2 --bucket "$(config__get .target.s3.bucket)" --prefix "$1/" \
    --delimiter / --output json \
    | jq -r --arg p "$1/" '(.Contents // [])[].Key | ltrimstr($p)'
}

################################################################################
# Every file under a directory.
# Arguments:
#   <dir>
# Outputs:
#   Their paths on stdout, one per line.
################################################################################
target__file_list_tree() {
  target__aws s3api list-objects-v2 --bucket "$(config__get .target.s3.bucket)" --prefix "$1/" \
    --output json \
    | jq -r '(.Contents // [])[].Key'
}
