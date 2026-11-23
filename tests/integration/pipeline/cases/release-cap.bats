# One poll admits at most max-releases releases (lowered to 3 here); the rest wait for the next.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a poll processes at most max-releases releases" {
  local repo tag
  repo=$(settings__get .repos.fixture.remote)
  # The next test's reset restores the seed config.
  distributor__default_config | sed 's/^max-releases: 256$/max-releases: 3/' \
    | distributor__push_config > /dev/null
  # Empty releases, a couple of seconds apart so discover orders them reliably.
  for tag in v1.0.1 v1.0.2 v1.0.3 v1.0.4; do
    github__release_create "$repo" "$tag"
    sleep 2
  done
  poll__run > /dev/null
  for tag in v1.0.1 v1.0.2 v1.0.3; do
    wait__check "first poll: $tag processed" \
      test "$(state__release_status "$repo" "$tag")" = rejected
  done
  wait__check "first poll: v1.0.4 left for later" \
    test "$(state__release_status "$repo" v1.0.4)" = absent
  poll__run > /dev/null
  wait__check "second poll: v1.0.4 processed" \
    test "$(state__release_status "$repo" v1.0.4)" = rejected
}
