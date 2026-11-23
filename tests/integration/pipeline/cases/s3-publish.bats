# A release is published to the bucket: packages cached as immutable, metadata and keys for
# metadata_max_age, the repository metadata signed by the archive key.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a release is published to the bucket with its cache headers" {
  local role=fixture repo fpr key meta tmp
  repo="$(settings__get ".repos.${role}.remote")"
  fpr="$(keys__fingerprint archive)"
  meta="public,max-age=$(settings__get .s3.metadata_max_age),must-revalidate"
  tmp="$(mktemp -d)"
  crafted__release_create "${role}" v1.0.0 "$(suite__repo_name "${repo}") 1.0.0"
  poll__run > /dev/null
  wait__check "v1.0.0: published" test "$(state__release_status "${repo}" v1.0.0)" = published
  for key in $(s3__release_keys "${repo}" v1.0.0); do
    wait__check "${key}: immutable" s3__has_cache_control "${key}" \
      'public,max-age=31536000,immutable'
  done
  for key in rpm/repodata/repomd.xml rpm/repodata/repomd.xml.asc deb/dists/stable/InRelease \
    deb/dists/stable/Release.gpg keys/archive.asc; do
    wait__check "${key}: ${meta}" s3__has_cache_control "${key}" "${meta}"
  done
  s3__get rpm/repodata/repomd.xml "${tmp}/repomd.xml"
  s3__get rpm/repodata/repomd.xml.asc "${tmp}/repomd.xml.asc"
  s3__get deb/dists/stable/InRelease "${tmp}/InRelease"
  wait__check "repomd.xml signed by the archive key" \
    keys__is_signed_by "${fpr}" "${tmp}/repomd.xml.asc" "${tmp}/repomd.xml"
  wait__check "InRelease signed by the archive key" keys__is_signed_by "${fpr}" "${tmp}/InRelease"
}
