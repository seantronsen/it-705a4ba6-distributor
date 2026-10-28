# shellcheck shell=bash
# Case 12: the name, version, and ownership rules, with crafted releases on the testbed and the
# second service repo. Check c (longer repo name) needs the second repo's name to start with the
# testbed's plus "-"; it's left out otherwise.

TAGS=()

case_cleanup() {
  local tag
  for tag in "${TAGS[@]}"; do release_drop "${tag%% *}" "${tag#* }" 2> /dev/null || true; done
}

craft() { # <repo> <tag> <deb spec>...
  craft_release "$@"
  TAGS+=("$1 $2")
}

# 0 when the release has this status and, if given, a reason containing <text>.
outcome() { # <repo> <tag> <status> [text]
  state_has --arg k "$1@$2" --arg s "$3" --arg r "${4:-}" \
    '.[$k].status == $s and ($r == "" or any(.[$k].reasons[]?; contains($r)))'
}

case_main() {
  local me longer=false
  me=$(short "$S")
  [[ $me == "$(short "$T")"-* ]] && longer=true
  # Clears any deny from earlier cases: the testbed's key must admit again.
  config_push '{"testbed_allow": ["it-shared", "it-twice"], "service2_allow": ["it-twice"]}'

  craft "$S" case12-a "zzz-other 1.0.0"
  craft "$S" case12-b "it-twice 1.0.0"
  $longer && craft "$T" case12-c "$me-x 1.0.0"
  craft "$T" case12-d1 "it-shared 1.0.0"
  craft "$S" case12-e "$me 1.0"
  craft "$S" case12-f "$me 1.0.0~rc1"
  craft "$S" case12-g "$me-dup 1.0.0 1" "$me-dup 1.0.0 2"
  poll_once > /dev/null
  check "a: a name the repo can't claim" \
    outcome "$S" case12-a rejected "zzz-other is not $me or $me-* and not in allow"
  check "b: a name in another repo's allow" \
    outcome "$S" case12-b rejected "it-twice is in another repo's allow"
  if $longer; then
    check "c: a name a longer repo name claims" \
      outcome "$T" case12-c rejected "belongs to a repo with a longer matching name"
  else
    log "c: left out ($me doesn't start with $(short "$T")-)"
  fi
  check "d1: an allowed name" outcome "$T" case12-d1 published
  check "e: not major.minor.patch" \
    outcome "$S" case12-e rejected "version 1.0 isn't major.minor.patch"
  check "f: a prerelease version" outcome "$S" case12-f skipped
  check "g: a duplicate package" \
    outcome "$S" case12-g rejected "duplicate deb package $me-dup 1.0.0"

  # Moving it-shared to the second repo's allow doesn't hand it over: the testbed published it.
  config_push '{"testbed_allow": ["it-twice"], "service2_allow": ["it-twice", "it-shared"]}'
  craft "$S" case12-d2 "it-shared 2.0.0"
  poll_once > /dev/null
  check "d2: a name another repo published first" \
    outcome "$S" case12-d2 rejected "it-shared is already published by $T"
}
