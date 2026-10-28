# shellcheck shell=bash
# Case 7: denying the testbed's repo key prunes everything it admitted, files a denial issue,
# and rejects later releases signed with it. The config push itself must trigger the poll
# (config_push errors if it doesn't).

denied_pruned() {
  testbed_packages | jq -se --arg r "denied repo key $TESTBED_FPR" 'any(.[]; .reason == $r)' \
    > /dev/null
}

denial_issue() {
  issues_get | jq -e --arg p "Denied repo key: $T $TESTBED_FPR (" \
    'any(.[]; .title | startswith($p))' > /dev/null
}

case_main() {
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  # Something to deny, unless an earlier case (10) already denied it all.
  denied_pruned || ensure_published v1.1.0
  config_push "$(deny_all_spec)"
  check "no testbed package still published" testbed_none_published
  check "pruned for the denied key" denied_pruned
  check "a denial issue" denial_issue

  local tag=v1.2.1
  gh release view "$tag" -R "$T" > /dev/null 2>&1 || tag_release "$tag"
  wait_for "$T $tag released" release_published "$T" "$tag" || exit 2
  poll_once > /dev/null
  check "$tag: rejected for the denied key" state_has --arg k "$T@$tag" --arg f "$TESTBED_FPR" \
    '.[$k].status == "rejected" and (.[$k].reasons | any(startswith("repo key \($f) is denied")))'
}
