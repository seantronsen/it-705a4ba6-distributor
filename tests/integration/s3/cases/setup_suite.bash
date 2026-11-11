# shellcheck shell=bash
# Once per run, around every test: the CI suite's, plus curl to read the bucket.

setup_suite() {
  source "$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/lifecycle.sh"
  source "$(dirname "${BASH_SOURCE[0]}")/../lib/s3.sh"
  s3__install_tools || return 1
  lifecycle__setup_suite
}

teardown_suite() {
  source "$(dirname "${BASH_SOURCE[0]}")/../../ci/lib/lifecycle.sh"
  lifecycle__teardown_suite
}
