# shellcheck shell=bash
# The run's throwaway key chain and the repo secrets made from it:
#
#   root      certify-only; MASTER_PUBLIC_ASC and MASTER_FPR on every repo
#   <role>    one repo key per service repo role (service, fixture), certify-only, user ID
#             "<owner>/<repo> RPM Signing Key", certified by the root; GPG_REPO_CERT_KEY_B64 on
#             the service repo (the fixture never builds)
#   archive   signs the distributor's published repositories; ARCHIVE_GPG_KEY on the distributor
#
# Plus other archive keys the tests make, public key files, and signature checks.

[[ -n "${_IT_KEYS_SH:-}" ]] && return 0
_IT_KEYS_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/../log.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite.sh"

################################################################################
# gpg on the run's GnuPG home (in the shared directory).
# Arguments:
#   gpg arguments.
################################################################################
keys__gpg() {
  GNUPGHOME="$(settings__get .run.share_dir)/gnupg" gpg "$@"
}

################################################################################
# A key's fingerprint, as keys__create recorded it.
# Arguments:
#   Role: root, archive, or a service repo role.
# Outputs:
#   The fingerprint on stdout.
################################################################################
keys__fingerprint() {
  cat "$(settings__get .run.share_dir)/keys/$1.fpr"
}

################################################################################
# Generates a key without a passphrase.
# Arguments:
#   User ID, algorithm, usage, expiry (gpg --quick-generate-key's arguments).
# Outputs:
#   The fingerprint on stdout.
# Returns:
#   0, or 1 when generation failed.
################################################################################
keys__generate() {
  local fpr
  fpr="$(keys__gpg --batch --yes --status-fd 1 --passphrase '' --pinentry-mode loopback \
    --quick-generate-key "$@" 2> /dev/null | awk '$2 == "KEY_CREATED" {print $4}')"
  if [[ -z "${fpr}" ]]; then
    log__error "can't generate a key for $1"
    return 1
  fi
  echo "${fpr}"
}

################################################################################
# Generates an archive key, like keys__create's, with a user ID of its own.
# Arguments:
#   Expiry, as gpg takes it (e.g. 60d).
# Outputs:
#   The fingerprint on stdout.
# Returns:
#   0, or 1 when generation failed.
################################################################################
keys__archive_generate() {
  keys__generate "distributor-it archive ${RANDOM} <it-archive@invalid>" \
    "$(settings__get .keys.algorithm_archive)" sign "$1"
}

################################################################################
# Certifies one key with another.
# Arguments:
#   Certifier fingerprint, subject fingerprint.
# Returns:
#   0, or 1 when certification failed.
################################################################################
keys__certify() {
  if ! keys__gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --quick-sign-key --local-user "$1" "$2" > /dev/null 2>&1; then
    log__error "$1 can't certify $2"
    return 1
  fi
}

################################################################################
# Creates the key chain and records each fingerprint (see keys__fingerprint).
# Returns:
#   0, or 1 when a key couldn't be made.
################################################################################
keys__create() {
  local dir root role fpr archive
  dir="$(settings__get .run.share_dir)"
  install -d -m 700 "${dir}/gnupg" "${dir}/keys"
  # Repo keys outlive gpg-sign-artifacts' 30-day expiry check, and the archive key check-keys'.
  root="$(keys__generate 'distributor-it root <it-root@invalid>' \
    "$(settings__get .keys.algorithm_attestation)" cert 7d)" || return 1
  echo "${root}" > "${dir}/keys/root.fpr"
  log__info "keys: root ${root}"
  for role in $(settings__get '.repos | del(.distributor) | keys[]'); do
    fpr="$(keys__generate "$(settings__get ".repos.${role}.remote") RPM Signing Key" \
      "$(settings__get .keys.algorithm_attestation)" cert 60d)" || return 1
    keys__certify "${root}" "${fpr}" || return 1
    echo "${fpr}" > "${dir}/keys/${role}.fpr"
    log__info "keys: ${role} ${fpr}"
  done
  archive="$(keys__archive_generate 60d)" || return 1
  echo "${archive}" > "${dir}/keys/archive.fpr"
  log__info "keys: archive ${archive}"
}

################################################################################
# Sets the distributor's ARCHIVE_GPG_KEY. Secrets reach gh on stdin only.
# Arguments:
#   A key's fingerprint, or "locked" for the run's archive key under a passphrase the
#   distributor doesn't have (it imports, so check-keys passes, but can't sign).
# Returns:
#   0, or 1 when the secret wasn't set.
################################################################################
keys__archive_secret_set() {
  if ! keys__archive_secret "$1" |
    gh secret set ARCHIVE_GPG_KEY -R "$(settings__get .repos.distributor.remote)"; then
    log__error "can't set ARCHIVE_GPG_KEY to $1"
    return 1
  fi
}

################################################################################
# The archive key secret's value.
# Arguments:
#   A fingerprint or "locked".
# Outputs:
#   The value on stdout.
################################################################################
keys__archive_secret() {
  if [[ "$1" == locked ]]; then
    keys__archive_locked
  else
    keys__gpg --armor --export-secret-keys "$1"
  fi
}

################################################################################
# The run's archive key under a passphrase.
# Outputs:
#   The armored secret key on stdout.
# Returns:
#   0, or 1 when the passphrase couldn't be set.
################################################################################
keys__archive_locked() {
  local home fpr status=0
  fpr="$(keys__fingerprint archive)"
  # A copy of the GnuPG home, so the run's own copy stays unprotected.
  home="$(mktemp -d)" || return 1
  cp -a "$(settings__get .run.share_dir)/gnupg/." "${home}/"
  if GNUPGHOME="${home}" gpg --batch --pinentry-mode loopback --passphrase distributor-it \
    --change-passphrase "${fpr}" 2> /dev/null; then
    GNUPGHOME="${home}" gpg --batch --pinentry-mode loopback --passphrase distributor-it \
      --armor --export-secret-keys "${fpr}"
  else
    log__error "can't lock the archive key"
    status=1
  fi
  GNUPGHOME="${home}" gpgconf --kill gpg-agent
  rm -rf "${home}"
  return "${status}"
}

################################################################################
# Sets every secret the repos need from the key chain.
# Returns:
#   0, or 1 when a secret wasn't set.
################################################################################
keys__secrets_set() {
  local repo
  for repo in $(settings__get '.repos[].remote'); do
    if ! keys__gpg --armor --export "$(keys__fingerprint root)" |
      gh secret set MASTER_PUBLIC_ASC -R "${repo}" ||
      ! printf '%s' "$(keys__fingerprint root)" | gh secret set MASTER_FPR -R "${repo}"; then
      log__error "can't set the root key secrets on ${repo}"
      return 1
    fi
  done
  if ! keys__gpg --armor --export-secret-keys "$(keys__fingerprint service)" | base64 -w0 |
    gh secret set GPG_REPO_CERT_KEY_B64 -R "$(settings__get .repos.service.remote)"; then
    log__error "can't set GPG_REPO_CERT_KEY_B64"
    return 1
  fi
  keys__archive_secret_set "$(keys__fingerprint archive)"
}

################################################################################
# Deletes every secret on the three repos.
# Returns:
#   0, or 1 when a secret couldn't be deleted.
################################################################################
keys__secrets_delete() {
  local repo name failed=false
  for repo in $(settings__get '.repos[].remote'); do
    for name in $(gh secret list -R "${repo}" --json name -q '.[].name'); do
      gh secret delete "${name}" -R "${repo}" || failed=true
    done
  done
  if ${failed}; then
    log__error "couldn't delete every secret"
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
keys__public_write() {
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
keys__is_signed_by() {
  keys__gpg --batch --status-fd 1 --verify "${@:2}" 2> /dev/null |
    grep -q "^\[GNUPG:\] VALIDSIG $1 "
}
