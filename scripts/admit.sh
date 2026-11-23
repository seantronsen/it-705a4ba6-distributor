#!/usr/bin/env bash
# Admit one release.
#
#   admit.sh <owner/repo> <tag> <outdir>
#
# Downloads the sidecars, checks that a publisher pushed the tag (config `publishers`), verifies
# the trust chain with github-actions' gpg-verify-trust-chain.sh (VERIFY_CHAIN_URL; root key from
# MASTER_PUBLIC_ASC and MASTER_FPR), then checks the packages.
#
# Writes <outdir>/result.json with status published, skipped, or rejected (plus reasons), and the
# admitted packages under <outdir>/files/. Exits non-zero only for infrastructure errors (API,
# downloads), which leave nothing to record so the next poll retries the release.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/github.sh"
source "$(dirname "$0")/lib/package.sh"
source "$(dirname "$0")/lib/state.sh"

SIDECARS=(checksums.txt checksums.txt.asc pubkey-signing.asc pubkey-repo.asc)

################################################################################
# Updates the admission's result.json with a jq filter.
# Arguments:
#   <outdir> <jq filter> [jq args...]
################################################################################
set_result() {
  local result=$1/result.json filter=$2
  shift 2
  jq "$@" "$filter" "$result" > "$result.tmp" && mv "$result.tmp" "$result"
}

################################################################################
# Ends the admission with a status and its reasons.
# Arguments:
#   <outdir> <published|skipped|rejected> [reason...]
################################################################################
finish() {
  local out=$1 status=$2
  shift 2
  set_result "$out" '.status = $st | .reasons += $r' --arg st "$status" \
    --argjson r "$(jq -nc '$ARGS.positional' --args "$@")"
  log__info "admit $(jq -r .key "$out/result.json"): $status${*:+ ($*)}"
  exit 0
}

################################################################################
# Rejects the release unless everyone who pushed its tag or ran its push runs may publish this
# repo (config `publishers`). Backstop for a repo missing its `v*` tag ruleset.
#
# Every run counts, not just the latest: the API doesn't say which run published the release.
# E.g. a non-publisher's run publishes, then a publisher re-pushes the tag; that run fails the
# draft guard, so the latest run is the publisher's but the release isn't. No run: rejected.
# Arguments:
#   <outdir> <owner/repo> <tag>
################################################################################
check_publisher() {
  local out=$1 repo=$2 tag=$3 pubs actors reasons=()
  pubs=$(config__get .publishers)
  actors=$(github__tag_push_actor_list "$repo" "$tag")
  [[ $(jq length <<< "$actors") -gt 0 ]] \
    || finish "$out" rejected "no push run found for tag $tag, so its publisher can't be checked"
  # Usernames are labels only; flag a listed ID whose username has since changed.
  base__jq -r --argjson p "$pubs" 'import "publishers" as publishers; publishers::renamed($p)' \
    <<< "$actors" | while read -r line; do log__info "$line"; done
  mapfile -t reasons < <(base__jq -r --argjson p "$pubs" --arg repo "$repo" \
    'import "publishers" as publishers; publishers::rejections($p; $repo)' <<< "$actors")
  [[ ${#reasons[@]} -eq 0 ]] || finish "$out" rejected "${reasons[@]}"
}

################################################################################
# Downloads the release's sidecars (SIDECARS) into release/; rejects the release when any is
# missing.
# Arguments:
#   <outdir> <owner/repo> <tag>
################################################################################
fetch_sidecars() {
  local out=$1 repo=$2 tag=$3 f id missing=()
  github__release_asset_list "$repo" "$tag" > "$out/assets.json"
  for f in "${SIDECARS[@]}"; do
    jq -e --arg n "$f" 'any(.name == $n)' "$out/assets.json" > /dev/null || missing+=("missing $f")
  done
  [[ ${#missing[@]} -eq 0 ]] || finish "$out" rejected "${missing[@]}"
  for f in "${SIDECARS[@]}"; do
    id=$(jq -r --arg n "$f" '.[] | select(.name == $n) | .id' "$out/assets.json")
    github__release_asset_download "$repo" "$id" "$out/release/$f"
  done
}

################################################################################
# Verifies the trust chain and checksums.txt's signature with github-actions'
# gpg-verify-trust-chain.sh, then records the repo key; rejects the release when it fails.
# Globals:
#   VERIFY_CHAIN_URL, MASTER_PUBLIC_ASC, MASTER_FPR
# Arguments:
#   <outdir> <owner/repo>
################################################################################
verify_chain() {
  local out=$1 repo=$2 fpr
  curl -fsSL --retry 3 "$VERIFY_CHAIN_URL" -o "$out/verify-chain.sh"
  MASTER_PUBLIC_KEY=${MASTER_PUBLIC_ASC:?MASTER_PUBLIC_ASC is required} \
    MASTER_FINGERPRINT=${MASTER_FPR:?MASTER_FPR is required} \
    REPO_KEY_FILE=$out/release/pubkey-repo.asc SIGNING_KEY_FILE=$out/release/pubkey-signing.asc \
    FILES=$out/release/checksums.txt REPO=$repo OUTPUT_FILE=$out/verify.out \
    bash "$out/verify-chain.sh" >&2 \
    || finish "$out" rejected \
      "trust chain or checksums.txt signature didn't verify (see the run log)"
  fpr=$(sed -n 's/^fingerprint-repo=//p' "$out/verify.out")
  set_result "$out" '.repo_key = $f' --arg f "${fpr^^}"
}

################################################################################
# Rejects the release when its repo key is denied (config `deny`).
# Arguments:
#   <outdir> <owner/repo>
################################################################################
check_denied_key() {
  local out=$1 repo=$2 repo_key denied
  repo_key=$(jq -r .repo_key "$out/result.json")
  denied=$(config__get .repos | base__jq -r --arg repo "$repo" --arg f "$repo_key" \
    'import "deny" as deny; deny::reason($repo; $f)')
  [[ -z $denied ]] || finish "$out" rejected "repo key $repo_key is denied: $denied"
}

################################################################################
# The packages checksums.txt lists ("<sha256>  <name>", or "<sha256> *<name>").
# Arguments:
#   <outdir>
# Outputs:
#   {name: sha256} as JSON on stdout.
################################################################################
read_checksums() {
  local out=$1 hash name
  while read -r hash name; do
    name=${name#\*}
    if [[ $name == *.rpm || $name == *.deb ]]; then
      printf '%s\t%s\n' "$name" "$hash"
    fi
  done < "$out/release/checksums.txt" \
    | jq -Rnc '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
}

################################################################################
# Downloads each listed package into files/; rejects the release when one isn't attached or its
# sha256 doesn't match.
# Arguments:
#   <outdir> <owner/repo> <checksums (read_checksums)>
################################################################################
fetch_packages() {
  local out=$1 repo=$2 checksums=$3 name want id got reasons=()
  while IFS=$'\t' read -r name want; do
    # GitHub renames "~" to "." in asset names.
    id=$(jq -r --arg a "$name" --arg b "${name//\~/.}" \
      '[.[] | select(.name == $a or .name == $b)][0].id // empty' "$out/assets.json")
    if [[ -z $id ]]; then
      reasons+=("$name is listed in checksums.txt but not attached")
      continue
    fi
    github__release_asset_download "$repo" "$id" "$out/files/$name"
    got=$(sha256sum "$out/files/$name" | cut -d' ' -f1)
    [[ $got == "$want" ]] || reasons+=("$name: sha256 $got doesn't match checksums.txt")
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$checksums")
  [[ ${#reasons[@]} -eq 0 ]] || finish "$out" rejected "${reasons[@]}"
}

################################################################################
# Each downloaded package's metadata, with its sha256, dropping (and deleting) packages of
# architectures the distributor doesn't publish.
# Arguments:
#   <outdir> <checksums (read_checksums)>
# Outputs:
#   The packages as a JSON array on stdout.
################################################################################
read_packages() {
  local out=$1 checksums=$2 name sha info arch infos='[]'
  while IFS=$'\t' read -r name sha; do
    info=$(package__metadata "$out/files/$name") || log__fatal "can't read package metadata: $name"
    arch=$(jq -r .arch <<< "$info")
    if ! package__is_arch_supported "$(jq -r .format <<< "$info")" "$arch"; then
      log__info "admit: ignoring $name (architecture $arch)"
      rm -f "$out/files/$name"
      continue
    fi
    infos=$(jq -c --argjson i "$info" --arg sha "$sha" '. + [$i + {sha256: $sha}]' <<< "$infos")
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$checksums")
  echo "$infos"
}

################################################################################
# Skips the release quietly when any package has a prerelease version.
# Arguments:
#   <outdir> <packages (read_packages)>
################################################################################
check_prerelease() {
  local out=$1 infos=$2
  if base__jq -e 'import "version" as version; any(.version | version::is_prerelease)' \
    <<< "$infos" > /dev/null; then
    rm -rf "$out/files"
    finish "$out" skipped "prerelease version"
  fi
}

################################################################################
# The packages whose version isn't major.minor.patch.
# Arguments:
#   <packages (read_packages)>
# Outputs:
#   A reason per package on stdout.
################################################################################
version_reasons() {
  base__jq -r 'import "version" as version; .[] | select(.version | version::is_release | not)
    | "\(.filename): version \(.version) isn'"'"'t major.minor.patch"' <<< "$1"
}

################################################################################
# The packages with the name, duplicate, and already-admitted rules applied. State goes to jq
# on stdin: it outgrows the command-line argument limit.
# Arguments:
#   <owner/repo> <packages (read_packages)>
# Outputs:
#   The packages as JSON on stdout, each with its reasons ([] when it passes).
################################################################################
apply_package_rules() {
  state__json | base__jq -c --arg repo "$1" --argjson cfg "$(config__get .repos)" \
    --argjson infos "$2" \
    'import "admit" as admit;
      . as $state | $infos | admit::package_rules_apply($state; $cfg; $repo)'
}

################################################################################
# Rejects the release on any version or package rule; else admits its packages.
# Arguments:
#   <outdir> <owner/repo> <packages (read_packages)>
################################################################################
check_packages() {
  local out=$1 repo=$2 infos=$3 reasons checked
  mapfile -t reasons < <(version_reasons "$infos")
  checked=$(apply_package_rules "$repo" "$infos")
  mapfile -t -O "${#reasons[@]}" reasons < <(jq -r '.[].reasons[]' <<< "$checked")
  [[ ${#reasons[@]} -eq 0 ]] || finish "$out" rejected "${reasons[@]}"
  set_result "$out" '.packages = [$c[] | del(.reasons)
    + {path: "files/\(.filename)", status: "published"}]' --argjson c "$checked"
  finish "$out" published
}

################################################################################
# Admits one release: writes a pending result.json, then runs the checks in order. The first
# that fails ends the admission (finish exits).
# Arguments:
#   <owner/repo> <tag> <outdir>
################################################################################
main() {
  local repo=$1 tag=$2 out checksums infos
  mkdir -p "$3/release" "$3/files"
  out=$(cd "$3" && pwd)
  jq -n --arg key "$repo@$tag" --arg repo "$repo" --arg tag "$tag" \
    --arg at "$(base__timestamp_utc)" --arg run "$(github__run_url)" '{key: $key, repo: $repo,
      tag: $tag, status: "pending", at: $at, run: $run, reasons: [], packages: []}' \
    > "$out/result.json"
  fetch_sidecars "$out" "$repo" "$tag"
  check_publisher "$out" "$repo" "$tag"
  verify_chain "$out" "$repo"
  check_denied_key "$out" "$repo"
  checksums=$(read_checksums "$out")
  fetch_packages "$out" "$repo" "$checksums"
  infos=$(read_packages "$out" "$checksums")
  check_prerelease "$out" "$infos"
  check_packages "$out" "$repo" "$infos"
}

[[ $# -eq 3 ]] || log__fatal "usage: admit.sh <owner/repo> <tag> <outdir>"
main "$@"
