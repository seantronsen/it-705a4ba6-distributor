# Denying a repo key prunes everything it admitted, opens a denial issue, and rejects its new
# releases.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a denied repo key is pruned and its new releases rejected" {
  local role=fixture repo name fpr
  repo=$(settings__get ".repos.$role.remote")
  name=$(suite__repo_name "$repo")
  fpr=$(keys__fpr fixture)
  crafted__release "$role" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  distributor__push_config > /dev/null << EOF
$(distributor__publishers)
repos:
  - name: $(settings__get .repos.service.remote)
    allow: $(settings__get '.repos.service.packages | tojson')
  - name: $repo
    deny:
      - fingerprint: $fpr
        reason: distributor-it
EOF
  wait__check "no package still published" state__has_none_published "$repo"
  wait__check "pruned for the denied key" state__has --arg k "$repo@v1.0.0" \
    --arg r "denied repo key $fpr" '.[$k].packages | all(.status == "pruned" and .reason == $r)'
  wait__check "a denial issue" distributor__has_denial "$repo" "$fpr"
  crafted__release "$role" v1.1.0 "$name 1.1.0"
  poll__run > /dev/null
  wait__check "v1.1.0: rejected for the denied key" state__has \
    --arg k "$repo@v1.1.0" --arg f "$fpr" \
    '.[$k].status == "rejected" and (.[$k].reasons | any(startswith("repo key \($f) is denied")))'
}
