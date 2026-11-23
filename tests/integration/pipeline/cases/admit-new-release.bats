# A new release that passes every check is admitted, and its packages are published.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a new release is admitted and its packages published" {
  local role=fixture repo name
  repo="$(settings__get ".repos.${role}.remote")"
  name="$(suite__repo_name "${repo}")"
  crafted__release_create "${role}" v1.0.0 "${name} 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: published, deb and rpm" state__has --arg k "${repo}@v1.0.0" '
    .[$k].status == "published"
    and (.[$k].packages | length == 2 and all(.status == "published"))'
}
