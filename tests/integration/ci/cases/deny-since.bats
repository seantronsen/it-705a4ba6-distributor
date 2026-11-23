# Denying a repo key from a date prunes only what it admitted since then.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a repo key denied since a date is pruned from that date only" {
  local role=fixture repo name fpr since
  repo=$(settings__get ".repos.$role.remote")
  name=$(suite__repo_name "$repo")
  fpr=$(keys__fpr fixture)
  crafted__release "$role" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  crafted__release "$role" v1.1.0 "$name 1.1.0"
  poll__run > /dev/null
  since=$(state__get | jq -r --arg k "$repo@v1.1.0" '.[$k].at')
  distributor__push_config > /dev/null << EOF
$(distributor__publishers)
repos:
  $(settings__get .repos.service.remote):
    allow: $(settings__get '.repos.service.packages | tojson')
  $repo:
    deny:
      - fingerprint: $fpr
        since: "$since"
        reason: distributor-it
EOF
  wait__check "v1.1.0: pruned for the denied key" state__has --arg k "$repo@v1.1.0" \
    --arg r "denied repo key $fpr" '.[$k].packages | all(.status == "pruned" and .reason == $r)'
  wait__check "v1.0.0: still published" state__has --arg k "$repo@v1.0.0" \
    '.[$k].packages | all(.status == "published")'
  wait__check "a denial issue" distributor__has_denial "$repo" "$fpr"
}
