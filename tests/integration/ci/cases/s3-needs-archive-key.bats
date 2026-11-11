# target.s3 without ARCHIVE_GPG_KEY fails the poll before discover (a throwaway key must never
# sign a real target): nothing is admitted or rejected. No bucket is reached, so none is needed.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

@test "target.s3 without an archive key fails the poll" {
  local role=fixture repo distributor run
  repo=$(settings__get ".repos.$role.remote")
  distributor=$(settings__get .repos.distributor.remote)
  crafted__release "$role" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  # lifecycle__reset sets it again.
  gh secret delete ARCHIVE_GPG_KEY -R "$distributor"
  run=$(distributor__push_config << EOF
$(distributor__default_config)
target:
  s3: {bucket: distributor-it-unreachable, region: us-east-1, metadata-max-age: 60}
EOF
  )
  wait__check "keys job failed" github__has_jobs_concluded "$distributor" "$run" keys failure
  wait__check "discover skipped" github__has_jobs_concluded "$distributor" "$run" discover skipped
  wait__check "v1.0.0: not processed" test "$(state__release_status "$repo" v1.0.0)" = absent
}
