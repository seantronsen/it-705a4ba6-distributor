# A publisher limited to some repos can't publish the others.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

@test "a publisher limited to the service repo can't publish the fixture" {
  local role=fixture repo service_repo name id
  repo=$(settings__get ".repos.$role.remote")
  service_repo=$(settings__get .repos.service.remote)
  name=$(suite__repo_name "$repo")
  id=$(github__user_id)
  distributor__push_config > /dev/null << EOF
publishers:
  "$id": {username: distributor-it, repos: [$service_repo]}
repos:
  - name: $service_repo
    allow: $(settings__get '.repos.service.packages | tojson')
  - name: $repo
EOF
  crafted__release "$role" v1.0.0 "$name 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: rejected, its pusher may not publish this repo" state__has \
    --arg k "$repo@v1.0.0" --arg r "may not publish $repo" \
    '.[$k].status == "rejected" and (.[$k].reasons | any(contains($r)))'
}
