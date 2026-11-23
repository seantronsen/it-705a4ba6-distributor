# A config that fails the schema fails the poll before discover: nothing is admitted or
# rejected, and nothing is committed. Fixing it admits normally.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "an invalid config fails the poll and touches nothing" {
  local role=fixture repo distributor run before
  repo=$(settings__get ".repos.$role.remote")
  distributor=$(settings__get .repos.distributor.remote)
  crafted__release "$role" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  # No publishers, and a key the schema doesn't know.
  run=$(distributor__push_config << EOF
$(distributor__target)
repos:
  $(settings__get .repos.service.remote):
    allow: $(settings__get '.repos.service.packages | tojson')
  $repo:
    colour: blue
EOF
  )
  wait__check "config job failed" github__has_jobs_concluded "$distributor" "$run" config failure
  wait__check "discover skipped" github__has_jobs_concluded "$distributor" "$run" discover skipped
  before=$(github__head_sha "$distributor")
  run=$(poll__run)
  wait__check "a dispatched poll fails too" \
    github__has_jobs_concluded "$distributor" "$run" config failure
  wait__check "no state commit" test "$(github__head_sha "$distributor")" = "$before"
  wait__check "v1.0.0: not processed" test "$(state__release_status "$repo" v1.0.0)" = absent
  distributor__default_config | distributor__push_config > /dev/null
  wait__check "fixed: v1.0.0 published" \
    test "$(state__release_status "$repo" v1.0.0)" = published
}
