# The whole pipeline with a real build: a service repo tag goes through GoReleaser and signing, and
# the distributor admits and publishes it. The published repositories are exported to
# artifacts/real-build for the distro tests. The only test that waits for a real release build.

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a real release is admitted and its repositories published" {
  local repo run dir
  repo=$(settings__get .repos.service.remote)
  service__release v1.0.0
  run=$(poll__run)
  wait__check "v1.0.0: 6 packages published" state__has --arg k "$repo@v1.0.0" \
    '.[$k].packages | length == 6 and all(.status == "published")'
  dir="$(settings__get .run.artifacts_dir)/real-build"
  rm -rf "$dir"
  poll__download_published "$run" "$dir"
  test -s "$dir/keys/archive.asc"
  test -d "$dir/rpm/repodata"
  test -d "$dir/deb/dists"
  log__info "exported to $dir"
}
