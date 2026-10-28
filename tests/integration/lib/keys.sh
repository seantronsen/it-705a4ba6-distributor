# shellcheck shell=bash
# The run's throwaway key chain, in the shared GNUPGHOME ($RUN/gnupg). Source it after common.sh.
#
#   root key        certify-only; MASTER_PUBLIC_ASC and MASTER_FPR on every repo
#   repo keys       one per service repo, certify-only, user ID "<owner>/<repo> RPM Signing Key",
#                   certified by the root key; GPG_REPO_CERT_KEY_B64 on the testbed
#   archive key     signs the published repositories; ARCHIVE_GPG_KEY on the distributor
#
# Fingerprints go to $RUN/run.env (ROOT_FPR, TESTBED_FPR, SERVICE2_FPR, ARCHIVE_FPR).

# Generates a key without a passphrase and prints its fingerprint (--yes: user IDs may repeat).
key_new() { # <user id> <algo> <usage> <expiry>
  gpg --batch --yes --status-fd 1 --passphrase '' --pinentry-mode loopback \
    --quick-generate-key "$1" "$2" "$3" "$4" 2> /dev/null \
    | awk '$2 == "KEY_CREATED" {print $4}'
}

certify() { # <certifier fpr> <subject fpr>
  gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --quick-sign-key --local-user "$1" "$2" > /dev/null 2>&1
}

keys_create() {
  local root testbed service2 archive
  mkdir -m 700 "$GNUPGHOME"
  # The repo keys must outlive gpg-sign-artifacts' 30-day expiry warning.
  root=$(key_new 'distributor-it root <it-root@invalid>' ed25519 cert 7d)
  testbed=$(key_new "$T RPM Signing Key" ed25519 cert 60d)
  service2=$(key_new "$S RPM Signing Key" ed25519 cert 60d)
  archive=$(key_new 'distributor-it archive <it-archive@invalid>' rsa3072 sign 7d)
  [[ -n $root && -n $testbed && -n $service2 && -n $archive ]] || die "key generation failed"
  certify "$root" "$testbed"
  certify "$root" "$service2"
  {
    echo "ROOT_FPR=$root"
    echo "TESTBED_FPR=$testbed"
    echo "SERVICE2_FPR=$service2"
    echo "ARCHIVE_FPR=$archive"
  } >> "$RUN/run.env"
  log "keys: root $root, testbed $testbed, service2 $service2, archive $archive"
}

# Secrets go to gh on stdin, so they never touch a file or a command line.
secrets_set() {
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  local repo
  for repo in "$D" "$T" "$S"; do
    gpg --armor --export "$ROOT_FPR" | gh secret set MASTER_PUBLIC_ASC -R "$repo"
    printf '%s' "$ROOT_FPR" | gh secret set MASTER_FPR -R "$repo"
  done
  gpg --armor --export-secret-keys "$TESTBED_FPR" | base64 -w0 \
    | gh secret set GPG_REPO_CERT_KEY_B64 -R "$T"
  gpg --armor --export-secret-keys "$ARCHIVE_FPR" | gh secret set ARCHIVE_GPG_KEY -R "$D"
}

secrets_delete() {
  local repo name
  for repo in "$D" "$T" "$S"; do
    for name in $(gh secret list -R "$repo" --json name -q '.[].name'); do
      gh secret delete "$name" -R "$repo"
    done
  done
}
