# Pruning deletes the packages from the bucket.

setup() {
  source "${BATS_TEST_DIRNAME}/../../lib/harness.sh"
  lifecycle__reset
}

teardown() {
  lifecycle__check_state
}

@test "a denied key's packages are deleted from the bucket" {
  local role=fixture repo keys key
  repo="$(settings__get ".repos.${role}.remote")"
  crafted__release_create "${role}" v1.0.0 "$(suite__repo_name "${repo}") 1.0.0"
  poll__run > /dev/null
  keys="$(s3__release_keys "${repo}" v1.0.0)"
  for key in ${keys}; do wait__check "${key}: on the bucket" s3__has_object "${key}"; done
  distributor__config_push > /dev/null << EOF
$(distributor__config_settings)
$(distributor__config_publishers)
repos:
  $(settings__get .repos.service.remote):
    allow: $(settings__get '.repos.service.packages | tojson')
  ${repo}:
    deny:
      - fingerprint: $(keys__fingerprint fixture)
        reason: distributor-it
EOF
  wait__check "no package still published" state__has_none_published "${repo}"
  for key in ${keys}; do wait__check "${key}: gone" s3__is_gone "${key}"; done
}
