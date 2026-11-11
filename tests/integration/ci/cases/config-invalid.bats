# A config that fails the schema fails the poll before discover: nothing is admitted or
# rejected, and nothing is committed. Fixing it admits normally.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../lib/github.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  lifecycle__reset
}

@test "an invalid config fails the poll and touches nothing" {
  local repo distributor run before
  repo=$(suite__service2_repo)
  distributor=$(suite__distributor_repo)
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  # No publishers, and a key the schema doesn't know.
  run=$(distributor__push_config << EOF
repos:
  - name: $(suite__testbed_repo)
    allow: [testbed, testbed-quadlet]
  - name: $repo
    colour: blue
EOF
  )
  wait__check "config job failed" github__jobs_concluded "$distributor" "$run" config failure
  wait__check "discover skipped" github__jobs_concluded "$distributor" "$run" discover skipped
  before=$(github__head_sha "$distributor")
  run=$(poll__run)
  wait__check "a dispatched poll fails too" \
    github__jobs_concluded "$distributor" "$run" config failure
  wait__check "no state commit" test "$(github__head_sha "$distributor")" = "$before"
  wait__check "v1.0.0: not processed" test "$(state__release_status "$repo" v1.0.0)" = absent
  distributor__default_config | distributor__push_config > /dev/null
  wait__check "fixed: v1.0.0 published" \
    test "$(state__release_status "$repo" v1.0.0)" = published
}
