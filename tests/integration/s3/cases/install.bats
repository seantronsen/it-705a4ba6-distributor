# Each distro's own package manager installs from the real bucket over its public HTTPS URL: a
# release (trusting the archive key from the harness, not the bucket), and openchami-keyring
# (then trusting the repository through it alone). Publishes once for every test.

setup_file() {
  source "$BATS_TEST_DIRNAME/../../ci/lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/archive.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/keys.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/state.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/workflow.sh"
  source "$BATS_TEST_DIRNAME/../lib/s3.sh"
  local repo dir
  repo=$(suite__service2_repo)
  dir=$(install_dir)
  lifecycle__reset
  s3__use > /dev/null
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: published" test "$(state__release_status "$repo" v1.0.0)" = published
  workflow__run keyring.yml > /dev/null
  wait__check "openchami-keyring 1.0.0: published" \
    test "$(state__get | jq -r '."openchami-keyring@1.0.0".status')" = published
  # The bootstrap key, mounted at /repo/keys/archive.asc like the files the distro suite tests.
  mkdir -p "$dir/keys"
  archive__write_public "$(keys__fpr archive)" "$dir/keys/archive.asc"
  s3__apt_https "$dir"
}

setup() {
  source "$BATS_TEST_DIRNAME/../../ci/lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../../lib/settings.sh"
  source "$BATS_TEST_DIRNAME/../../distro/lib/images.sh"
  source "$BATS_TEST_DIRNAME/../../distro/lib/install.sh"
  source "$BATS_TEST_DIRNAME/../../distro/lib/target.sh"
  source "$BATS_TEST_DIRNAME/../lib/s3.sh"
}

# Where the bootstrap key and apt's CA files go: under artifacts/, the same path on the host,
# where the engine mounts from.
install_dir() { echo "$(suite__artifacts_dir)/s3-install"; }

# The crafted release's package name.
package() { suite__repo_name "$(suite__service2_repo)"; }

@test "fedora: dnf installs a release from the bucket" {
  target__dnf "$(images__fedora)" "$(install_dir)" "$(settings__get .s3.url)" "$(package)"
}

@test "debian: apt installs a release from the bucket" {
  local -a opts
  mapfile -t opts < <(s3__apt_https_options "$(install_dir)")
  target__apt "$(images__debian)" "$(install_dir)" "$(settings__get .s3.url)" "$(package)" \
    "${opts[@]}"
}

@test "fedora: the keyring installs from the bucket and verifies it" {
  install__keyring_dnf "$(images__fedora)" "$(install_dir)" "$(settings__get .s3.url)"
}

@test "debian: the keyring installs from the bucket and verifies it" {
  local -a opts
  mapfile -t opts < <(s3__apt_https_options "$(install_dir)")
  install__keyring_apt "$(images__debian)" "$(install_dir)" "$(settings__get .s3.url)" \
    "${opts[@]}"
}
