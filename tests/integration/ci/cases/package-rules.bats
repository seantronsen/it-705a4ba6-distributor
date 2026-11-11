# Package name, version, and ownership rules across two service repos.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

################################################################################
# Whether a release ended with a status and, if given, a reason containing some text.
# Arguments:
#   Repo path (owner/name), tag, status, reason text (optional).
# Returns:
#   0 when it did, 1 otherwise.
################################################################################
outcome() {
  state__has --arg k "$1@$2" --arg s "$3" --arg r "${4:-}" \
    '.[$k].status == $s and ($r == "" or any(.[$k].reasons[]?; contains($r)))'
}

@test "package names, versions, and ownership follow the rules" {
  local service_repo fixture_repo me longer=false
  service_repo=$(settings__get .repos.service.remote)
  fixture_repo=$(settings__get .repos.fixture.remote)
  me=$(suite__repo_name "$fixture_repo")
  # The longer-name rule needs the fixture's name to start with the service repo's plus "-".
  if [[ $me == "$(suite__repo_name "$service_repo")"-* ]]; then longer=true; fi

  distributor__push_config > /dev/null << EOF
$(distributor__publishers)
repos:
  - name: $service_repo
    allow: $(settings__get '.repos.service.packages + ["it-shared", "it-twice"] | tojson')
  - name: $fixture_repo
    allow: [it-twice]
EOF
  crafted__release fixture v1.0.0-a "zzz-other 1.0.0"
  crafted__release fixture v1.0.0-b "it-twice 1.0.0"
  if $longer; then crafted__release service it-c "$me-x 1.0.0"; fi
  crafted__release service it-d1 "it-shared 1.0.0"
  crafted__release fixture v1.0.0-e "$me 1.0"
  crafted__release fixture v1.0.0-f "$me 1.0.0~rc1"
  crafted__release fixture v1.0.0-g "$me-dup 1.0.0 1" "$me-dup 1.0.0 2"
  poll__run > /dev/null
  wait__check "a: a name the repo can't claim" outcome "$fixture_repo" v1.0.0-a rejected \
    "zzz-other is not $me or $me-* and not in allow"
  wait__check "b: a name in another repo's allow" outcome "$fixture_repo" v1.0.0-b rejected \
    "it-twice is in another repo's allow"
  if $longer; then
    wait__check "c: a name a longer repo name claims" outcome "$service_repo" it-c rejected \
      "belongs to a repo with a longer matching name"
  else
    log__info "c: left out ($me doesn't start with $(suite__repo_name "$service_repo")-)"
  fi
  wait__check "d1: an allowed name" outcome "$service_repo" it-d1 published
  wait__check "e: not major.minor.patch" outcome "$fixture_repo" v1.0.0-e rejected \
    "version 1.0 isn't major.minor.patch"
  wait__check "f: a prerelease version" outcome "$fixture_repo" v1.0.0-f skipped
  wait__check "g: a duplicate package" outcome "$fixture_repo" v1.0.0-g rejected \
    "duplicate deb package $me-dup 1.0.0"

  # Moving it-shared to the fixture's allow doesn't hand it over: the service repo published it.
  distributor__push_config > /dev/null << EOF
$(distributor__publishers)
repos:
  - name: $service_repo
    allow: $(settings__get '.repos.service.packages + ["it-twice"] | tojson')
  - name: $fixture_repo
    allow: [it-twice, it-shared]
EOF
  crafted__release fixture v1.0.0-d2 "it-shared 2.0.0"
  poll__run > /dev/null
  wait__check "d2: a name another repo published first" outcome "$fixture_repo" v1.0.0-d2 rejected \
    "it-shared is already published by $service_repo"
}
