#!/usr/bin/env bash
# Deletes the throwaway repos init.sh recorded in the state file, after you confirm their names,
# and the service repo's images in your GHCR namespace; then deletes the state file. Repos set in
# your config are never touched.
#
# Needs the delete_repo scope, and delete:packages for the images:
#   gh auth refresh -s delete_repo,delete:packages
set -uo pipefail

# shellcheck source=lib/log.sh
source "$(dirname "$0")/lib/log.sh"
# shellcheck source=lib/config.sh
source "$(dirname "$0")/lib/config.sh"

################################################################################
# One value from the state file.
# Arguments:
#   jq path (e.g. .service).
# Outputs:
#   The value on stdout, empty when missing.
# Returns:
#   0, or 1 when the file can't be read.
################################################################################
state() {
  local json
  json="$(config__json "$(config__file_state_repos)")" || return 1
  jq -r "$1 // empty" <<< "${json}"
}

main() {
  local file owner role repo repos=() list image images=() answer failed=false
  file="$(config__file_state_repos)"
  if [[ ! -f "${file}" ]]; then
    log__error "${file} not found: init.sh created no repos to destroy"
    failed=true
  fi
  if ! owner="$(gh api user -q .login)"; then
    log__error "gh isn't logged in (gh auth login)"
    failed=true
  fi
  ${failed} && exit 1

  # Only what init.sh creates: under this account and named like it. Every repo is checked
  # before anything is refused.
  for role in distributor service fixture; do
    repo="$(state ".${role}")" || exit 1
    if [[ ! "${repo}" =~ ^${owner}/it-[0-9a-f]{8}-(distributor|testbed|testbed-tools)$ ]]; then
      log__error "refusing to delete '${repo}': init.sh only creates" \
        "${owner}/it-<8 hex digits>-{distributor,testbed,testbed-tools}"
      failed=true
    elif gh api "repos/${repo}" > /dev/null 2>&1; then
      repos+=("${repo}")
    else
      log__error "${repo} doesn't exist; skipping it"
    fi
  done
  ${failed} && log__fatal "nothing deleted: ${file} lists repos init.sh doesn't create"
  # Whatever images the service repo's releases published, named by its own GoReleaser config:
  # the ones in this account's namespace linked to that repo.
  repo="$(state .service)" || exit 1
  if ! list=$(gh api --paginate 'user/packages?package_type=container' |
    jq -r --arg r "${repo}" '.[] | select(.repository.full_name == $r) | .name'); then
    log__fatal "can't list your GHCR images (gh auth refresh -s delete:packages)"
  fi
  [[ -z "${list}" ]] || mapfile -t images <<< "${list}"

  if ((${#repos[@]} + ${#images[@]})); then
    printf '%s\n' "These will be deleted:" "${repos[@]/#/  repo }" \
      "${images[@]/#/  image ghcr.io/${owner,,}/}" >&2
    read -r -p "Type Y to delete them: " answer
    [[ "${answer}" == Y ]] || log__fatal "nothing deleted"
  fi
  for repo in "${repos[@]}"; do
    if gh repo delete "${repo}" --yes; then log__info "deleted ${repo}"; else failed=true; fi
  done
  for image in "${images[@]}"; do
    if gh api -X DELETE "user/packages/container/${image}" > /dev/null; then
      log__info "deleted ghcr.io/${owner,,}/${image}"
    else
      failed=true
    fi
  done

  # Kept until everything is gone, so a rerun finishes the job.
  if ${failed}; then
    log__fatal "not everything was deleted (scopes: gh auth refresh -s delete_repo,delete:packages)"
  fi
  rm -f "${file}"
  log__info "removed ${file}"
}

main
