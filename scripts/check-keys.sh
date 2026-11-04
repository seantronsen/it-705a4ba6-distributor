#!/usr/bin/env bash
# Check the archive key, at the start of every poll.
#
#   check-keys.sh
#
# Fails when ARCHIVE_GPG_KEY isn't keys/archive.asc (archive_key_init) or expires within
# WARN_DAYS, and keeps the "Archive key expiring" and "Archive key switch due" issues open or
# closed to match. Skipped for a throwaway key (local target, no ARCHIVE_GPG_KEY).
source "$(dirname "$0")/lib.sh"

WARN_DAYS=30
EXPIRING="Archive key expiring"
SWITCH_DUE="Archive key switch due"

# Days until the archive key's primary key or a signing subkey expires; nothing if it never does.
days_to_expiry() {
  local expires
  expires=$(gpg --batch --with-colons --list-keys "$ARCHIVE_FPR" \
    | awk -F: '($1=="pub" || ($1=="sub" && $12 ~ /s/)) && $7 != "" {print $7}' | sort -n | head -1)
  [[ -z $expires ]] || echo $(((expires - $(date +%s)) / 86400))
}

# Fails within WARN_DAYS of expiry.
check_expiry() {
  local days
  days=$(days_to_expiry)
  if [[ -n $days && $days -lt $WARN_DAYS ]]; then
    log "check-keys: archive key $ARCHIVE_FPR expires in $days day(s)"
    issue_ensure "$EXPIRING" archive-key "Archive key \`$ARCHIVE_FPR\` expires in $days day(s). \
Rotate it (spec-deferred.md, Archive key management). Run: $(run_url)"
    return 1
  fi
  issue_close "$EXPIRING" archive-key "The archive key no longer expires within $WARN_DAYS days."
}

# Days since keys/archive-next.asc was first committed; nothing if it isn't there.
days_since_next_key() {
  local added
  [[ -f $ROOT/keys/archive-next.asc ]] || return 0
  added=$(git -C "$ROOT" log --diff-filter=A --format=%ct -- keys/archive-next.asc | tail -1)
  [[ -n $added ]] || die "keys/archive-next.asc has no history (check out with full history)"
  echo $((($(date +%s) - added) / 86400))
}

# Reminds a maintainer to switch keys once the grace period is over. Never fails the run.
check_switch_due() {
  local days
  days=$(days_since_next_key)
  if [[ -z $days ]]; then
    issue_close "$SWITCH_DUE" archive-key "keys/archive-next.asc is gone: the switch is done."
  elif [[ $days -ge $WARN_DAYS ]]; then
    issue_ensure "$SWITCH_DUE" archive-key "\`keys/archive-next.asc\` was committed $days days ago, \
so clients have had the keyring carrying it for the grace period. Switch keys now \
(spec-deferred.md, Rotation, step 3)."
  fi
}

target_init
if [[ -z ${ARCHIVE_GPG_KEY:-} ]]; then
  log "check-keys: ARCHIVE_GPG_KEY not set (throwaway key); skipped"
  exit 0
fi
archive_key_init
check_switch_due
check_expiry
log "check-keys: archive key $ARCHIVE_FPR OK"
