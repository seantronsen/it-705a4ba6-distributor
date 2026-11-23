# shellcheck shell=bash
# The archive key: loading it, signing rpms with it, and publishing keys/.

[[ -n ${_LIB_KEYS_SH:-} ]] && return 0
_LIB_KEYS_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/base.sh"
source "$(dirname "${BASH_SOURCE[0]}")/target.sh"

################################################################################
# Sets up a private GNUPGHOME holding the archive secret key, or a throwaway key without
# ARCHIVE_GPG_KEY. Exits when the key doesn't import, isn't exactly one secret key, or isn't
# keys/archive.asc.
# Globals:
#   ARCHIVE_GPG_KEY (armored or base64), ARCHIVE_GPG_PASSPHRASE; sets and exports GNUPGHOME,
#   ARCHIVE_FPR, and ARCHIVE_PUB (the exported public key's file).
################################################################################
keys__init_archive() {
  local fprs
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  chmod 700 "$GNUPGHOME"
  printf 'pinentry-mode loopback\ntrust-model always\n' > "$GNUPGHOME/gpg.conf"
  if [[ -n ${ARCHIVE_GPG_PASSPHRASE:-} ]]; then
    printf '%s' "$ARCHIVE_GPG_PASSPHRASE" > "$GNUPGHOME/passphrase"
    echo "passphrase-file $GNUPGHOME/passphrase" >> "$GNUPGHOME/gpg.conf"
  fi

  if [[ -n ${ARCHIVE_GPG_KEY:-} ]]; then
    if grep -q 'BEGIN PGP' <<< "$ARCHIVE_GPG_KEY"; then
      printf '%s\n' "$ARCHIVE_GPG_KEY"
    else
      base64 -d <<< "$ARCHIVE_GPG_KEY"
    fi | gpg --batch --quiet --import 2> /dev/null || log__fatal "ARCHIVE_GPG_KEY doesn't import"
  else
    gpg --batch --quiet --passphrase '' --quick-generate-key \
      'OpenCHAMI throwaway archive key' rsa3072 sign 1y 2> /dev/null
    log__info "ARCHIVE_GPG_KEY not set: signing with a throwaway archive key"
  fi

  fprs=$(gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1=="sec" {s=1} s && $1=="fpr" {print $10; s=0}')
  [[ $(wc -l <<< "$fprs") -eq 1 && -n $fprs ]] \
    || log__fatal "the archive key must be exactly one secret key"
  ARCHIVE_FPR=$fprs
  ARCHIVE_PUB=$GNUPGHOME/archive-public.asc
  gpg --batch --armor --export "$ARCHIVE_FPR" > "$ARCHIVE_PUB"
  export ARCHIVE_FPR ARCHIVE_PUB

  # A real key must be the committed one (keys/archive.asc), e.g. not half through a switch.
  if [[ -n ${ARCHIVE_GPG_KEY:-} && -f $ROOT/keys/archive.asc ]]; then
    [[ $(keys__file_fpr "$ROOT/keys/archive.asc") == "$ARCHIVE_FPR" ]] \
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
keys__file_fpr() {
  gpg --batch --with-colons --show-keys "$1" 2> /dev/null | awk -F: '$1=="fpr" {print $10; exit}'
}

################################################################################
# Signs rpms with the archive key.
# Globals:
#   ARCHIVE_FPR, GNUPGHOME (keys__init_archive)
# Arguments:
#   <rpm>...
################################################################################
keys__sign_rpm() {
  # Ubuntu's rpm macros point __gpg at a path that may not exist; use the gpg on PATH.
  rpmsign --addsign --define "__gpg $(command -v gpg)" --define "_gpg_name $ARCHIVE_FPR" \
    --define "_gpg_path $GNUPGHOME" "$@" > /dev/null
}

################################################################################
# Replaces any signature on rpms with the archive key's.
# Arguments:
#   <rpm>...
################################################################################
keys__resign_rpm() {
  rpmsign --delsign "$@" > /dev/null
  keys__sign_rpm "$@"
}

################################################################################
# Publishes keys/ (archive.asc, and during a rotation or after a compromise archive-next.asc,
# archive-previous.asc, revoked-<fpr>.asc) and removes keys no longer there. Without a committed
# keys/archive.asc (throwaway key), publishes the archive public key alone.
# Globals:
#   ARCHIVE_PUB (keys__init_archive)
################################################################################
keys__publish() {
  local f
  if [[ ! -f $ROOT/keys/archive.asc ]]; then
    target__put "$ARCHIVE_PUB" keys/archive.asc
    return
  fi
  for f in "$ROOT"/keys/*.asc; do target__put "$f" "keys/${f##*/}"; done
  for f in $(target__ls keys); do
    [[ -e $ROOT/keys/$f ]] || target__rm "keys/$f"
  done
}
