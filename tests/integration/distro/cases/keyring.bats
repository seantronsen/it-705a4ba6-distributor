# openchami-keyring, installed by each distro's own package manager, then trusted alone to
# verify the repository: from the files, and over HTTP from a temporary S3 gateway. Stage 1 runs
# ci/cases/keyring.bats to produce them.

setup_file() {
  source "$BATS_TEST_DIRNAME/../lib/stage.sh"
  source "$BATS_TEST_DIRNAME/../lib/gateway.sh"
  stage__ci keyring
  gateway__start
  gateway__load "$(stage__artifacts keyring)"
}

teardown_file() {
  source "$BATS_TEST_DIRNAME/../lib/gateway.sh"
  gateway__stop
}

setup() {
  source "$BATS_TEST_DIRNAME/../lib/stage.sh"
  source "$BATS_TEST_DIRNAME/../lib/gateway.sh"
  source "$BATS_TEST_DIRNAME/../lib/images.sh"
  source "$BATS_TEST_DIRNAME/../lib/install.sh"
}

@test "fedora: the keyring installs from the files and verifies the repository" {
  install__keyring_dnf "$(images__fedora)" "$(stage__artifacts keyring)" file:///repo
}

@test "debian: the keyring installs from the files and verifies the repository" {
  install__keyring_apt "$(images__debian)" "$(stage__artifacts keyring)" file:///repo
}

@test "fedora: the keyring installs over HTTP and verifies the repository" {
  install__keyring_dnf "$(images__fedora)" "$(stage__artifacts keyring)" "$(gateway__url)" \
    --network "$(gateway__network)"
}

@test "debian: the keyring installs over HTTP and verifies the repository" {
  install__keyring_apt "$(images__debian)" "$(stage__artifacts keyring)" "$(gateway__url)" \
    --network "$(gateway__network)"
}
