# The whole pipeline with a real build: a testbed tag goes through GoReleaser and signing, the
# distributor admits and publishes it, and dnf and apt install it from the published
# repositories with signatures checked. The only test that waits for a real release build.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/install.sh"
  lifecycle__reset
}

@test "a real release installs with dnf and apt from the published repositories" {
  local repo run dir
  repo=$(suite__testbed_repo)
  testbed__release v1.0.0
  run=$(distributor__poll)
  wait__check "v1.0.0: 6 packages published" distributor__state_has --arg k "$repo@v1.0.0" \
    '.[$k].packages | length == 6 and all(.status == "published")'
  dir="$(suite__share_dir)/install-real-build"
  rm -rf "$dir"
  distributor__download_published "$run" "$dir"
  wait__check "the published repositories carry the archive key" \
    test -s "$dir/rpm/keys/archive.asc" -a -s "$dir/deb/keys/archive.asc"
  install__dnf "$dir/rpm" testbed
  install__apt "$dir/deb" testbed
}
