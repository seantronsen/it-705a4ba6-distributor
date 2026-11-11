# Each keyring build bumps the patch, so retention keeps only the latest keyring.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/lifecycle.sh"
  source "$BATS_TEST_DIRNAME/../lib/poll.sh"
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
  source "$BATS_TEST_DIRNAME/../lib/wait.sh"
  source "$BATS_TEST_DIRNAME/../lib/workflow.sh"
  lifecycle__reset
}

@test "a second keyring build bumps the patch and prunes the first" {
  workflow__run keyring.yml > /dev/null
  workflow__run keyring.yml > /dev/null
  wait__check "1.0.1: published" state__has \
    '.["openchami-keyring@1.0.1"].packages | length == 2 and all(.status == "published")'
  poll__run > /dev/null
  wait__check "1.0.0: pruned by retention" state__has \
    '.["openchami-keyring@1.0.0"].packages | all(.status == "pruned" and .reason == "retention")'
  wait__check "1.0.1: still published" state__has \
    '.["openchami-keyring@1.0.1"].packages | all(.status == "published")'
}
