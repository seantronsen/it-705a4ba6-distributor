# A release whose tag was pushed by someone not in publishers is rejected.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a release pushed by a non-publisher is rejected" {
  local role=fixture repo name
  repo=$(settings__get ".repos.$role.remote")
  name=$(suite__repo_name "$repo")
  # GitHub user 1 is someone else: the suite's user isn't a publisher.
  distributor__push_config > /dev/null << EOF
publishers:
  "1": {username: mojombo}
repos:
  - name: $(settings__get .repos.service.remote)
    allow: $(settings__get '.repos.service.packages | tojson')
  - name: $repo
EOF
  crafted__release "$role" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: rejected, its pusher may not publish" state__has \
    --arg k "$repo@v1.0.0" --arg r "may not publish $repo" \
    '.[$k].status == "rejected" and (.[$k].reasons | any(contains($r)))'
}
