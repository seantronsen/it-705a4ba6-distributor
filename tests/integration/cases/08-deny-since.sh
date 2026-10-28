# shellcheck shell=bash
# Case 8: a deny with `since` prunes only what its key admitted from then on. Retention keeps the
# latest patch of each minor, so v1.1.0 and v1.2.0 are both published before the deny.

pruned_denied() { # <tag>
  state_has --arg k "$T@$1" --arg r "denied repo key $TESTBED_FPR" \
    '.[$k].packages | all(.status == "pruned" and .reason == $r)'
}

denial_issue() {
  issues_get | jq -e --arg p "Denied repo key: $T $TESTBED_FPR (" \
    'any(.[]; .state == "OPEN" and (.title | startswith($p)))' > /dev/null
}

case_main() {
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  local since spec
  ensure_published v1.1.0
  ensure_published v1.2.0
  since=$(state_get | jq -r --arg k "$T@v1.2.0" '.[$k].at')
  spec=$(jq -nc --arg f "$TESTBED_FPR" --arg s "$since" \
    '{deny: [{fingerprint: $f, since: $s, reason: "distributor-it"}]}')
  config_push "$spec"
  check "v1.2.0: pruned for the denied key" pruned_denied v1.2.0
  check "v1.1.0: still published" state_has --arg k "$T@v1.1.0" \
    '.[$k].packages | all(.status == "published")'
  check "a denial issue" denial_issue
}
