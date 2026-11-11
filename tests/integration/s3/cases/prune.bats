# Pruning deletes the packages from the bucket.

setup() {
  source "$BATS_TEST_DIRNAME/../../ci/lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/crafted.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/distributor.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/keys.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/state.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/suite.sh"
  source "$BATS_TEST_DIRNAME/../../ci/lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../lib/s3.sh"
  lifecycle__reset
}

@test "a denied key's packages are deleted from the bucket" {
  local repo keys key
  repo=$(suite__service2_repo)
  s3__use > /dev/null
  crafted__release "$repo" v1.0.0 "$(suite__repo_name "$repo") 1.0.0"
  poll__run > /dev/null
  keys=$(s3__release_keys "$repo" v1.0.0)
  for key in $keys; do wait__check "$key: on the bucket" s3__exists "$key"; done
  distributor__push_config > /dev/null << EOF
$(distributor__publishers)
repos:
  - name: $(suite__testbed_repo)
    allow: [testbed, testbed-quadlet]
  - name: $repo
    deny:
      - fingerprint: $(keys__fpr service2)
        reason: distributor-it
$(s3__config | sed -n '/^target:/,$p')
EOF
  wait__check "no package still published" state__none_published "$repo"
  for key in $keys; do wait__check "$key: gone" s3__gone "$key"; done
}
