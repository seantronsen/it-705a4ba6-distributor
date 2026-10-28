# shellcheck shell=bash
# Case 2: a release is published; the next patch release prunes it (retention).

six_published() { # <tag>
  state_has --arg k "$T@$1" '.[$k].packages | length == 6 and all(.status == "published")'
}

case_main() {
  ensure_published v1.0.0
  check "v1.0.0: 6 packages published" six_published v1.0.0
  ensure_published v1.0.1
  check "v1.0.1: 6 packages published" six_published v1.0.1
  check "v1.0.0: every package pruned for retention" state_has --arg k "$T@v1.0.0" \
    '.[$k].packages | all(.status == "pruned" and .reason == "retention")'
}
