# shellcheck shell=bash
# Once per run, around every test: the pipeline suite's.

setup_suite() {
  source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
  lifecycle__suite_setup
}

teardown_suite() {
  source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
  lifecycle__suite_teardown
}
