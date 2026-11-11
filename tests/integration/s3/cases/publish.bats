# A release is published to the bucket: packages cached as immutable, metadata and keys for
# metadata-max-age, the repository metadata signed by the archive key.

setup() {
  source "$BATS_TEST_DIRNAME/../../ci/lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/archive.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/keys.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/state.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../lib/s3.sh"
  lifecycle__reset
}

@test "a release is published to the bucket with its cache headers" {
  local repo fpr key meta tmp
  repo=$(suite__service2_repo)
  fpr=$(keys__fpr archive)
  meta="public,max-age=$(s3__max_age),must-revalidate"
  tmp=$(mktemp -d)
  s3__use > /dev/null
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: published" test "$(state__release_status "$repo" v1.0.0)" = published
  for key in $(s3__release_keys "$repo" v1.0.0); do
    wait__check "$key: immutable" s3__cache_control_is "$key" 'public,max-age=31536000,immutable'
  done
  for key in rpm/repodata/repomd.xml rpm/repodata/repomd.xml.asc deb/dists/stable/InRelease \
    deb/dists/stable/Release.gpg keys/archive.asc; do
    wait__check "$key: $meta" s3__cache_control_is "$key" "$meta"
  done
  s3__get rpm/repodata/repomd.xml "$tmp/repomd.xml"
  s3__get rpm/repodata/repomd.xml.asc "$tmp/repomd.xml.asc"
  s3__get deb/dists/stable/InRelease "$tmp/InRelease"
  wait__check "repomd.xml signed by the archive key" \
    archive__signed_by "$fpr" "$tmp/repomd.xml.asc" "$tmp/repomd.xml"
  wait__check "InRelease signed by the archive key" archive__signed_by "$fpr" "$tmp/InRelease"
}
