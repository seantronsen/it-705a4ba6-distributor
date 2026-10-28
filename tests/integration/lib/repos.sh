# shellcheck shell=bash
# Guarding, resetting, and seeding the throwaway repos. Source it after common.sh.

# Refuses anything that isn't clearly one of our throwaway repos: nothing under OpenCHAMI,
# public (the distributor reads the service repos without a token of theirs), and a repo with
# history must carry the marker file this suite pushed.
guard() {
  local repo owner info
  for repo in "$D" "$T" "$S"; do
    owner=${repo%%/*}
    [[ $repo == */* ]] || die "$repo: expected owner/repo"
    [[ ${owner,,} != openchami ]] || die "$repo: refusing a repo under OpenCHAMI"
    info=$(gh api "repos/$repo") || die "$repo: not found (create it first; it can be empty)"
    [[ $(jq -r .visibility <<< "$info") == public ]] || die "$repo: must be public"
    [[ $(jq -r .fork <<< "$info") == false ]] || die "$repo: must not be a fork"
    # An empty repo has no commits yet; anything else must be ours.
    if gh api "repos/$repo/commits?per_page=1" > /dev/null 2>&1; then
      gh api "repos/$repo/contents/$MARKER" > /dev/null 2>&1 \
        || die "$repo: has history but no $MARKER; refusing to overwrite it"
    fi
  done
  [[ ${D%%/*} == "${T%%/*}" && ${D%%/*} == "${S%%/*}" ]] || die "the three repos need one owner"
}

# Deletes everything a run leaves on a repo: releases and tags, issues, labels the distributor
# creates, and workflow runs (with their artifacts and logs).
wipe() { # <owner/repo>
  local repo=$1 x
  log "wipe: $repo"
  for x in $(gh api --paginate "repos/$repo/releases?per_page=100" -q '.[].tag_name'); do
    gh release delete "$x" -R "$repo" --cleanup-tag --yes
  done
  # An empty repo has no refs to list (HTTP 409).
  if gh api "repos/$repo/commits?per_page=1" > /dev/null 2>&1; then
    for x in $(gh api --paginate "repos/$repo/git/matching-refs/tags" -q '.[].ref'); do
      gh api -X DELETE "repos/$repo/git/$x"
    done
  fi
  for x in $(gh issue list -R "$repo" --state all -L 1000 --json number -q '.[].number'); do
    gh issue delete "$x" -R "$repo" --yes
  done
  for x in rejected-release denied-repo-key prune-failing; do
    gh label delete "$x" -R "$repo" --yes 2> /dev/null || true
  done
  for x in $(gh api --paginate "repos/$repo/actions/runs?per_page=100" \
    -q '.workflow_runs[] | select(.status != "completed") | .id'); do
    gh api -X POST "repos/$repo/actions/runs/$x/cancel" > /dev/null 2>&1 || true
  done
  wait_for "$repo: no active runs" runs_idle "$repo"
  for x in $(gh api --paginate "repos/$repo/actions/runs?per_page=100" -q '.workflow_runs[].id'); do
    gh api -X DELETE "repos/$repo/actions/runs/$x"
  done
}

runs_idle() { # <owner/repo>
  [[ $(gh api "repos/$1/actions/runs?per_page=100" \
    -q '[.workflow_runs[] | select(.status != "completed")] | length') == 0 ]]
}

# Force-pushes the local checkouts' HEAD commits, plus one commit with the suite's changes:
#   distributor   test config (test_config), empty state, no schedule (the suite dispatches
#                 every poll; a stray scheduled one would race the checks), the marker
#   testbed       images under the owner's GHCR namespace instead of OpenCHAMI's, the marker
#   service2      just the marker (it only holds crafted releases)
seed() {
  local owner=${T%%/*}
  git clone --quiet /src/distributor "$WORK/seed-d"
  test_config '{}' | yq -P -p json > "$WORK/seed-d/config/repos.yaml"
  echo '{}' > "$WORK/seed-d/state/state.json"
  sed -i '/^  schedule:$/,/^    - cron:/d' "$WORK/seed-d/.github/workflows/poll.yml"
  ! grep -q 'cron:' "$WORK/seed-d/.github/workflows/poll.yml" || die "can't drop poll's schedule"
  echo "distributor-it" > "$WORK/seed-d/$MARKER"
  commit_all "$WORK/seed-d" "it: test config, empty state"
  git -C "$WORK/seed-d" remote set-url origin "https://github.com/$D.git"
  push_main "$WORK/seed-d" --force

  git clone --quiet /src/testbed "$WORK/seed-t"
  sed -i "s|ghcr.io/openchami/github-actions-testbed|ghcr.io/${owner,,}/$(short "$T")|" \
    "$WORK/seed-t/.goreleaser.yaml"
  echo "distributor-it" > "$WORK/seed-t/$MARKER"
  commit_all "$WORK/seed-t" "it: images under ${owner,,}"
  git -C "$WORK/seed-t" remote set-url origin "https://github.com/$T.git"
  push_main "$WORK/seed-t" --force

  mkdir "$WORK/seed-s"
  git -C "$WORK/seed-s" init --quiet
  echo "distributor-it" > "$WORK/seed-s/$MARKER"
  commit_all "$WORK/seed-s" "it: marker"
  git -C "$WORK/seed-s" remote add origin "https://github.com/$S.git"
  push_main "$WORK/seed-s" --force
}
