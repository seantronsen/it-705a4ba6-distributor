# shellcheck shell=bash
# The archive key: loading it, signing rpms with it, and publishing keys/.

[[ -n ${_LIB_KEYS_SH:-} ]] && return 0
_LIB_KEYS_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"
source "$(dirname "${BASH_SOURCE[0]}")/target.sh"

################################################################################
# Sets up a private GNUPGHOME holding the archive secret key. Exits when ARCHIVE_GPG_KEY is unset,
# doesn't import, isn't exactly one secret key, or isn't keys/archive.asc (when committed).
# Globals:
#   ARCHIVE_GPG_KEY (armored or base64), ARCHIVE_GPG_PASSPHRASE; sets and exports GNUPGHOME,
#   ARCHIVE_FPR, and ARCHIVE_PUB (the exported public key's file).
################################################################################
keys__archive_load() {
  local fprs
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  chmod 700 "$GNUPGHOME"
  printf 'pinentry-mode loopback\ntrust-model always\n' > "$GNUPGHOME/gpg.conf"
  if [[ -n ${ARCHIVE_GPG_PASSPHRASE:-} ]]; then
    printf '%s' "$ARCHIVE_GPG_PASSPHRASE" > "$GNUPGHOME/passphrase"
    echo "passphrase-file $GNUPGHOME/passphrase" >> "$GNUPGHOME/gpg.conf"
  fi

  [[ -n ${ARCHIVE_GPG_KEY:-} ]] || log__fatal "ARCHIVE_GPG_KEY is required"
  if grep -q 'BEGIN PGP' <<< "$ARCHIVE_GPG_KEY"; then
    printf '%s\n' "$ARCHIVE_GPG_KEY"
  else
    base64 -d <<< "$ARCHIVE_GPG_KEY"
  fi | gpg --batch --quiet --import 2> /dev/null || log__fatal "ARCHIVE_GPG_KEY doesn't import"

  fprs=$(gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1=="sec" {s=1} s && $1=="fpr" {print $10; s=0}')
  [[ $(wc -l <<< "$fprs") -eq 1 && -n $fprs ]] \
    || log__fatal "the archive key must be exactly one secret key"
  ARCHIVE_FPR=$fprs
  ARCHIVE_PUB=$GNUPGHOME/archive-public.asc
  gpg --batch --armor --export "$ARCHIVE_FPR" > "$ARCHIVE_PUB"
  export ARCHIVE_FPR ARCHIVE_PUB

  # The key must be the committed one (keys/archive.asc), e.g. not half through a switch.
  if [[ -f $ROOT/keys/archive.asc ]]; then
    [[ $(keys__file_fingerprint "$ROOT/keys/archive.asc") == "$ARCHIVE_FPR" ]] \
      || log__fatal "ARCHIVE_GPG_KEY ($ARCHIVE_FPR) isn't keys/archive.asc"
  fi
}

################################################################################
# A key file's primary key fingerprint.
# Arguments:
#   <armored public key file>
# Outputs:
#   The fingerprint on stdout.
################################################################################
keys__file_fingerprint() {
  gpg --batch --with-colons --show-keys "$1" 2> /dev/null | awk -F: '$1=="fpr" {print $10; exit}'
}

################################################################################
# Signs rpms with the archive key.
# Globals:
#   ARCHIVE_FPR, GNUPGHOME (keys__archive_load)
# Arguments:
#   <rpm>...
################################################################################
keys__rpm_sign() {
  # Ubuntu's rpm macros point __gpg at a path that may not exist; use the gpg on PATH.
  rpmsign --addsign --define "__gpg $(command -v gpg)" --define "_gpg_name $ARCHIVE_FPR" \
    --define "_gpg_path $GNUPGHOME" "$@" > /dev/null
}

################################################################################
# Replaces any signature on rpms with the archive key's.
# Arguments:
#   <rpm>...
################################################################################
keys__rpm_resign() {
  rpmsign --delsign "$@" > /dev/null
  keys__rpm_sign "$@"
}

################################################################################
# Publishes keys/ (archive.asc, and during a rotation or after a compromise archive-next.asc,
# archive-previous.asc, revoked-<fpr>.asc) and removes keys no longer there. Without a committed
# keys/archive.asc, publishes the archive public key alone.
# Globals:
#   ARCHIVE_PUB (keys__archive_load)
################################################################################
keys__public_publish() {
  local f
  if [[ ! -f $ROOT/keys/archive.asc ]]; then
    target__file_put "$ARCHIVE_PUB" keys/archive.asc
    return
  fi
  for f in "$ROOT"/keys/*.asc; do target__file_put "$f" "keys/${f##*/}"; done
  for f in $(target__file_list keys); do
    [[ -e $ROOT/keys/$f ]] || target__file_delete "keys/$f"
  done
}
