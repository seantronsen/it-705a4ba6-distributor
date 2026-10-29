#!/usr/bin/env bash
# Deletes the throwaway repos init.sh recorded in repos.yaml, after you confirm their names, and
# the testbed's images in your GHCR namespace; then deletes repos.yaml.
#
# Needs the delete_repo scope, and delete:packages for the images:
#   gh auth refresh -s delete_repo,delete:packages
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib/log.sh"
source "$HERE/lib/config.sh"

main() {
  local file owner role repo repos=() image images=() answer failed=false
  file=$(config__repos_file)
  [[ -f $file ]] || log__die "$file not found: nothing to destroy"
  owner=$(gh api user -q .login) || log__die "gh isn't logged in (gh auth login)"

  # Only what init.sh makes: under this account and named like it. Gone ones are skipped.
  for role in distributor testbed service2; do
    repo=$(config__read "$file" ".$role") || exit 1
    [[ $repo =~ ^$owner/it-[0-9a-f]{8}-(distributor|testbed|testbed-tools)$ ]] ||
      log__die "$repo: not a repo init.sh makes for $owner"
    if gh api "repos/$repo" > /dev/null 2>&1; then repos+=("$repo"); fi
  done
  repo=$(config__read "$file" .testbed)
  for image in "${repo#*/}" "${repo#*/}-alt"; do
    if gh api "user/packages/container/$image" > /dev/null 2>&1; then images+=("$image"); fi
  done

  if ((${#repos[@]})); then
    printf '%s\n' "These repos will be deleted:" "${repos[@]/#/  }" >&2
    read -r -p "Type Y to delete them: " answer
    [[ $answer == Y ]] || log__die "nothing deleted"
    for repo in "${repos[@]}"; do
      if gh repo delete "$repo" --yes; then log__info "deleted $repo"; else failed=true; fi
    done
  fi
  for image in "${images[@]}"; do
    if gh api -X DELETE "user/packages/container/$image" > /dev/null; then
      log__info "deleted ghcr.io/${owner,,}/$image"
    else
      failed=true
    fi
  done

  # Kept until everything is gone, so a rerun finishes the job.
  $failed &&
    log__die "not everything was deleted (scopes: gh auth refresh -s delete_repo,delete:packages)"
  rm -f "$file"
  log__info "removed $file"
}

main "$@"
