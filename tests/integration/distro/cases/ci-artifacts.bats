# The CI real build's published repositories, installed by each distro's own package manager:
# from the files themselves, and over HTTP from a temporary S3 gateway the way users will install
# from S3. Stage 1 runs ci/cases/real-build.bats to produce them.

setup_file() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  stage__ci real-build
  gateway__start
  gateway__load "$(stage__artifacts real-build)"
}

teardown_file() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
  gateway__stop
}

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/harness.sh"
}

# The real build's package: the service repo's first.
package() { settings__get '.repos.service.packages[0]'; }

@test "fedora: dnf installs from the files" {
  target__install_dnf "$(settings__get .containers.images.fedora)" \
    "$(stage__artifacts real-build)" file:///repo "$(package)"
}

@test "debian: apt installs from the files" {
  target__install_apt "$(settings__get .containers.images.debian)" \
    "$(stage__artifacts real-build)" file:///repo "$(package)"
}

@test "fedora: dnf installs over HTTP from the S3 gateway" {
  target__install_dnf "$(settings__get .containers.images.fedora)" \
    "$(stage__artifacts real-build)" "$(gateway__url)" "$(package)" \
    --network "$(gateway__network)"
}

@test "debian: apt installs over HTTP from the S3 gateway" {
  target__install_apt "$(settings__get .containers.images.debian)" \
    "$(stage__artifacts real-build)" "$(gateway__url)" "$(package)" \
    --network "$(gateway__network)"
}
