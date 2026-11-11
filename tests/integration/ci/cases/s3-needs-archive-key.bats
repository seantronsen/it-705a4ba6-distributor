# target.s3 without ARCHIVE_GPG_KEY fails the poll before discover (a throwaway key must never
# sign a real target): nothing is admitted or rejected. No bucket is reached, so none is needed.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../lib/github.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  lifecycle__reset
}

@test "target.s3 without an archive key fails the poll" {
  local repo distributor run
  repo=$(suite__service2_repo)
  distributor=$(suite__distributor_repo)
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  # lifecycle__reset sets it again.
  gh secret delete ARCHIVE_GPG_KEY -R "$distributor"
  run=$(distributor__push_config << EOF
$(distributor__default_config)
target:
  s3: {bucket: distributor-it-unreachable, region: us-east-1, metadata-max-age: 60}
EOF
  )
  wait__check "keys job failed" github__jobs_concluded "$distributor" "$run" keys failure
  wait__check "discover skipped" github__jobs_concluded "$distributor" "$run" discover skipped
  wait__check "v1.0.0: not processed" test "$(state__release_status "$repo" v1.0.0)" = absent
}
