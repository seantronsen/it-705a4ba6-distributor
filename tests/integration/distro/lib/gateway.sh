# shellcheck shell=bash
# A temporary local S3 gateway (versitygw) serving published repositories over HTTP the way S3
# will: one public-read bucket, its files in the run's shared directory, on a private network
# the distro containers join. Deleted when the test file ends.

[[ -n ${_IT_GATEWAY_SH:-} ]] && return 0
_IT_GATEWAY_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/engine.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/images.sh"

################################################################################
# The gateway's container, network, and directory (in the shared directory, so the same path on
# the host), named after the run.
# Outputs:
#   The name or path on stdout.
################################################################################
gateway__name() { echo "distributor-it-gateway-$(basename "$(suite__share_dir)")"; }
gateway__network() { echo "$(gateway__name)-net"; }
gateway__dir() { echo "$(suite__share_dir)/gateway"; }

################################################################################
# The bucket's base URL, for containers on the gateway's network.
# Outputs:
#   The URL on stdout.
################################################################################
gateway__url() { echo "http://$(gateway__name):7070/repo"; }

################################################################################
# Starts the gateway with a random root secret. Its metadata goes to a sidecar directory: the
# shared directory is on tmpfs, which may not support the extended attributes versitygw uses.
# Globals:
#   IT_ENGINE
# Returns:
#   0, or 1 when it didn't start.
################################################################################
gateway__start() {
  local dir
  dir=$(gateway__dir)
  install -d -m 700 "$dir/data" "$dir/meta"
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$dir/secret"
  if ! "$IT_ENGINE" network create "$(gateway__network)" > /dev/null; then
    log__error "can't create the network $(gateway__network)"
    return 1
  fi
  if ! engine__run -d --name "$(gateway__name)" --network "$(gateway__network)" -v "$dir:/gw" \
    -e ROOT_ACCESS_KEY_ID=it -e "ROOT_SECRET_ACCESS_KEY=$(< "$dir/secret")" \
    "$(images__versitygw)" posix --sidecar /gw/meta /gw/data > /dev/null; then
    log__error "can't start the gateway"
    return 1
  fi
  log__info "gateway: $(gateway__url)"
}

################################################################################
# Uploads a directory's files to the bucket and makes it public-read (objects only: anonymous
# listing stays denied), from a container on the gateway's network.
# Arguments:
#   Directory (a path on the host).
# Returns:
#   0, or 1 when an upload failed.
################################################################################
gateway__load() {
  if ! engine__run -i --network "$(gateway__network)" -v "$1:/src:ro" \
    -e "GATEWAY=http://$(gateway__name):7070" -e "SECRET=$(< "$(gateway__dir)/secret")" \
    "$(images__fedora)" bash -s << 'EOF'; then
set -euo pipefail
auth=(--aws-sigv4 aws:amz:us-east-1:s3 --user "it:$SECRET")
# The gateway may still be starting.
for _ in {1..30}; do
  if curl -sf -o /dev/null "${auth[@]}" -X PUT "$GATEWAY/repo"; then break; fi
  sleep 1
done
curl -sSf -o /dev/null "${auth[@]}" -X PUT "$GATEWAY/repo?policy=" --data-binary \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*",
    "Action":["s3:GetObject"],"Resource":["arn:aws:s3:::repo/*"]}]}'
cd /src
find . -type f -printf '%P\n' | while IFS= read -r file; do
  curl -sSf -o /dev/null "${auth[@]}" -T "$file" "$GATEWAY/repo/$file"
done
EOF
    log__error "can't load $1 into the gateway"
    return 1
  fi
  log__info "gateway: loaded $1"
}

################################################################################
# Stops the gateway and deletes its network and files. Safe when it never started.
# Globals:
#   IT_ENGINE
################################################################################
gateway__stop() {
  "$IT_ENGINE" rm -f "$(gateway__name)" > /dev/null 2>&1
  "$IT_ENGINE" network rm "$(gateway__network)" > /dev/null 2>&1
  rm -rf "$(gateway__dir)"
}
