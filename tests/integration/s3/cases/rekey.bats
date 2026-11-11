# After a key switch (rotation step 3), the rekey workflow re-signs every published rpm and the
# repository metadata with the new key, records it as signed_with, and publishes its public key.

setup() {
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
  lifecycle__reset
}

# Whether a release's rpms are all recorded as signed with a key.
rpms_signed_with() {
  state__has --arg k "$1" --arg f "$2" \
    '.[$k].packages | map(select(.format == "rpm")) | length > 0 and all(.signed_with == $f)'
}

@test "rekey re-signs the bucket with the new archive key" {
  local repo old new tmp
  repo=$(suite__service2_repo)
  old=$(keys__fpr archive)
  tmp=$(mktemp -d)
  s3__use > /dev/null
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: rpm signed with the old key" rpms_signed_with "$repo@v1.0.0" "$old"
  new=$(archive__new 60d)
  archive__set_secret "$new"
  workflow__run rekey.yml > /dev/null
  wait__check "v1.0.0: rpm signed with the new key" rpms_signed_with "$repo@v1.0.0" "$new"
  s3__get rpm/repodata/repomd.xml "$tmp/repomd.xml"
  s3__get rpm/repodata/repomd.xml.asc "$tmp/repomd.xml.asc"
  s3__get deb/dists/stable/InRelease "$tmp/InRelease"
  s3__get "$(s3__release_keys "$repo" v1.0.0 | grep '^rpm/')" "$tmp/package.rpm"
  s3__get keys/archive.asc "$tmp/archive.asc"
  wait__check "repomd.xml signed by the new key" \
    archive__signed_by "$new" "$tmp/repomd.xml.asc" "$tmp/repomd.xml"
  wait__check "InRelease signed by the new key" archive__signed_by "$new" "$tmp/InRelease"
  # Downloaded files: no GitHub lag to wait out.
  rpm -qpi "$tmp/package.rpm" 2> /dev/null | grep -qi "key id ${new: -16}"
  keys__gpg --batch --show-keys --with-colons "$tmp/archive.asc" 2> /dev/null | grep -q ":$new:"
}
