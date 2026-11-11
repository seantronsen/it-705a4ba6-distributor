# shellcheck shell=bash
# Archive keys besides the run's own (keys__create): new keys for a switch, a soon-expiring key,
# or a mismatch, set as the distributor's secret or written as public key files.

[[ -n ${_IT_ARCHIVE_SH:-} ]] && return 0
_IT_ARCHIVE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/keys.sh"

################################################################################
# Generates an archive key, like keys__create's.
# Arguments:
#   Expiry (e.g. 60d).
# Outputs:
#   The fingerprint on stdout.
# Returns:
#   0, or 1 when generation failed.
################################################################################
archive__new() {
  keys__new "distributor-it archive $RANDOM <it-archive@invalid>" rsa3072 sign "$1"
}

################################################################################
# Sets a key as the distributor's ARCHIVE_GPG_KEY. Secrets reach gh on stdin only.
# Arguments:
#   Fingerprint.
# Returns:
#   0, or 1 when the secret wasn't set.
################################################################################
archive__set_secret() {
  if ! keys__gpg --armor --export-secret-keys "$1" |
    gh secret set ARCHIVE_GPG_KEY -R "$(suite__distributor_repo)"; then
    log__error "can't set ARCHIVE_GPG_KEY to $1"
    return 1
  fi
}

################################################################################
# Writes a key's public key as a file, creating its directory.
# Arguments:
#   Fingerprint, file.
# Returns:
#   0, or 1 when it can't be written.
################################################################################
archive__write_public() {
  if ! mkdir -p "$(dirname "$2")" || ! keys__gpg --armor --export "$1" > "$2"; then
    log__error "can't write $1's public key to $2"
    return 1
  fi
}

################################################################################
# Whether a file is signed by a key: a detached signature, or (no signature file) a clearsigned
# file.
# Arguments:
#   Fingerprint, signature or clearsigned file, signed file (optional).
# Returns:
#   0 when it verifies with that key, 1 otherwise.
################################################################################
archive__signed_by() {
  keys__gpg --batch --status-fd 1 --verify "${@:2}" 2> /dev/null |
    grep -q "^\[GNUPG:\] VALIDSIG $1 "
}
