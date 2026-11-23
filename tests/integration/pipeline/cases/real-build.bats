# The whole pipeline with a real build: a service repo tag goes through GoReleaser and signing, and
# the distributor admits and publishes it to the bucket. The only test that waits for a real
# release build.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a real release is admitted and its repositories published" {
  local repo key
  repo="$(settings__get .repos.service.remote)"
  service__release_create v1.0.0
  poll__run > /dev/null
  wait__check "v1.0.0: 6 packages published" state__has --arg k "${repo}@v1.0.0" \
    '.[$k].packages | length == 6 and all(.status == "published")'
  for key in keys/archive.asc rpm/repodata/repomd.xml deb/dists/stable/InRelease \
    $(s3__release_keys "${repo}" v1.0.0); do
    wait__check "${key}: on the bucket" s3__has_object "${key}"
  done
}
