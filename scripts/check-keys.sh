#!/usr/bin/env bash
# Check the archive key, at the start of every poll.
#
#   check-keys.sh
#
# Fails when ARCHIVE_GPG_KEY isn't keys/archive.asc (keys__init_archive) or expires within
# WARN_DAYS, and keeps the "Archive key expiring" and "Archive key switch due" issues open or
# closed to match. Skipped for a throwaway key (local target, no ARCHIVE_GPG_KEY).
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/keys.sh"
source "$(dirname "$0")/lib/target.sh"

WARN_DAYS=30
EXPIRING="Archive key expiring"
SWITCH_DUE="Archive key switch due"

################################################################################
# Days until the archive key's primary key or a signing subkey expires.
# Outputs:
#   The days on stdout, or nothing if it never expires.
################################################################################
days_to_expiry() {
  local expires
  expires=$(gpg --batch --with-colons --list-keys "$ARCHIVE_FPR" \
    | awk -F: '($1=="pub" || ($1=="sub" && $12 ~ /s/)) && $7 != "" {print $7}' | sort -n | head -1)
  [[ -z $expires ]] || echo $(((expires - $(date +%s)) / 86400))
}

################################################################################
# Opens the expiring issue within WARN_DAYS of expiry, else closes it.
# Returns:
#   1 within WARN_DAYS of expiry, so the run fails.
################################################################################
check_expiry() {
  local days
  days=$(days_to_expiry)
  if [[ -n $days && $days -lt $WARN_DAYS ]]; then
    log__info "check-keys: archive key $ARCHIVE_FPR expires in $days day(s)"
    github__ensure_issue "$EXPIRING" archive-key \
      "Archive key \`$ARCHIVE_FPR\` expires in $days day(s). Rotate it (spec-deferred.md, Archive \
key management). Run: $(github__run_url)"
    return 1
  fi
  github__close_issue "$EXPIRING" archive-key \
    "The archive key no longer expires within $WARN_DAYS days."
}

################################################################################
# Days since keys/archive-next.asc was first committed.
# Outputs:
#   The days on stdout, or nothing if it isn't there.
################################################################################
days_since_next_key() {
  local added
  [[ -f $ROOT/keys/archive-next.asc ]] || return 0
  added=$(git -C "$ROOT" log --diff-filter=A --format=%ct -- keys/archive-next.asc | tail -1)
  [[ -n $added ]] || log__fatal "keys/archive-next.asc has no history (check out with full history)"
  echo $((($(date +%s) - added) / 86400))
}

################################################################################
# Reminds a maintainer to switch keys once the grace period is over. Never fails the run.
################################################################################
check_switch_due() {
  local days
  days=$(days_since_next_key)
  if [[ -z $days ]]; then
    github__close_issue "$SWITCH_DUE" archive-key \
      "keys/archive-next.asc is gone: the switch is done."
  elif [[ $days -ge $WARN_DAYS ]]; then
    github__ensure_issue "$SWITCH_DUE" archive-key \
      "\`keys/archive-next.asc\` was committed $days days ago, so clients have had the keyring \
carrying it for the grace period. Switch keys now (spec-deferred.md, Rotation, step 3)."
  fi
}

target__init
if [[ -z ${ARCHIVE_GPG_KEY:-} ]]; then
  log__info "check-keys: ARCHIVE_GPG_KEY not set (throwaway key); skipped"
  exit 0
fi
keys__init_archive
check_switch_due
check_expiry
log__info "check-keys: archive key $ARCHIVE_FPR OK"
