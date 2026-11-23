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

[[ $# -eq 3 ]] || log__fatal "usage: admit.sh <owner/repo> <tag> <outdir>"
repo=$1 tag=$2 out=$3
mkdir -p "$out/release" "$out/files"
out=$(cd "$out" && pwd)
result=$out/result.json
SIDECARS=(checksums.txt checksums.txt.asc pubkey-signing.asc pubkey-repo.asc)

jq -n --arg key "$repo@$tag" --arg repo "$repo" --arg tag "$tag" --arg at "$(base__now)" \
  --arg run "$(github__run_url)" '{key: $key, repo: $repo, tag: $tag, status: "pending", at: $at,
    run: $run, reasons: [], packages: []}' > "$result"

################################################################################
# Updates result.json with a jq filter.
# Arguments:
#   <jq filter> [jq args...]
################################################################################
set_result() {
  local filter=$1
  shift
  jq "$@" "$filter" "$result" > "$result.tmp" && mv "$result.tmp" "$result"
}

################################################################################
# Ends the admission with a status and its reasons.
# Arguments:
#   <published|skipped|rejected> [reason...]
################################################################################
finish() {
  local st=$1
  shift
  set_result '.status = $st | .reasons += $r' --arg st "$st" \
    --argjson r "$(jq -nc '$ARGS.positional' --args "$@")"
  log__info "admit $repo@$tag: $st${*:+ ($*)}"
  exit 0
}

cfg=$(config__get .repos)

################################################################################
# Rejects the release unless everyone who pushed its tag or ran its push runs may publish this
# repo (config `publishers`). Backstop for a repo missing its `v*` tag ruleset.
#
# Every run counts, not just the latest: the API doesn't say which run published the release.
# E.g. a non-publisher's run publishes, then a publisher re-pushes the tag; that run fails the
# draft guard, so the latest run is the publisher's but the release isn't. No run: rejected.
################################################################################
check_publisher() {
  local pubs actors reasons=()
  pubs=$(config__get .publishers)
  actors=$(github__tag_push_actors "$repo" "$tag")
  [[ $(jq length <<< "$actors") -gt 0 ]] \
    || finish rejected "no push run found for tag $tag, so its publisher can't be checked"
  # Usernames are labels only; flag a listed ID whose username has since changed.
  base__jq -r --argjson p "$pubs" 'import "publishers" as publishers; publishers::renamed($p)' \
    <<< "$actors" | while read -r line; do log__info "$line"; done
  mapfile -t reasons < <(base__jq -r --argjson p "$pubs" --arg repo "$repo" \
    'import "publishers" as publishers; publishers::rejections($p; $repo)' <<< "$actors")
  [[ ${#reasons[@]} -eq 0 ]] || finish rejected "${reasons[@]}"
}

################################################################################
# Downloads the release's sidecars (SIDECARS) into release/; rejects the release when any is
# missing.
################################################################################
fetch_sidecars() {
  local f id missing=()
  github__assets "$repo" "$tag" > "$out/assets.json"
  for f in "${SIDECARS[@]}"; do
    jq -e --arg n "$f" 'any(.name == $n)' "$out/assets.json" > /dev/null || missing+=("missing $f")
  done
  [[ ${#missing[@]} -eq 0 ]] || finish rejected "${missing[@]}"
  for f in "${SIDECARS[@]}"; do
    id=$(jq -r --arg n "$f" '.[] | select(.name == $n) | .id' "$out/assets.json")
    github__fetch_asset "$repo" "$id" "$out/release/$f"
  done
}

################################################################################
# Verifies the trust chain and checksums.txt's signature with github-actions'
# gpg-verify-trust-chain.sh, then records the repo key; rejects the release when it fails.
# Globals:
#   VERIFY_CHAIN_URL, MASTER_PUBLIC_ASC, MASTER_FPR
################################################################################
verify_chain() {
  local fpr
  curl -fsSL --retry 3 "$VERIFY_CHAIN_URL" -o "$out/verify-chain.sh"
  MASTER_PUBLIC_KEY=${MASTER_PUBLIC_ASC:?MASTER_PUBLIC_ASC is required} \
    MASTER_FINGERPRINT=${MASTER_FPR:?MASTER_FPR is required} \
    REPO_KEY_FILE=$out/release/pubkey-repo.asc SIGNING_KEY_FILE=$out/release/pubkey-signing.asc \
    FILES=$out/release/checksums.txt REPO=$repo OUTPUT_FILE=$out/verify.out \
    bash "$out/verify-chain.sh" >&2 \
    || finish rejected "trust chain or checksums.txt signature didn't verify (see the run log)"
  fpr=$(sed -n 's/^fingerprint-repo=//p' "$out/verify.out")
  set_result '.repo_key = $f' --arg f "${fpr^^}"
}

################################################################################
# Rejects the release when its repo key is denied (config `deny`).
################################################################################
check_denied_key() {
  local repo_key denied
  repo_key=$(jq -r .repo_key "$result")
  denied=$(base__jq -r --arg repo "$repo" --arg f "$repo_key" \
    'import "deny" as deny; deny::reason($repo; $f)' <<< "$cfg")
  [[ -z $denied ]] || finish rejected "repo key $repo_key is denied: $denied"
}

################################################################################
# Reads the packages checksums.txt lists ("<sha256>  <name>", or "<sha256> *<name>") into want:
# name -> sha256.
################################################################################
read_checksums() {
  local hash name
  while read -r hash name; do
    name=${name#\*}
    [[ $name == *.rpm || $name == *.deb ]] && want[$name]=$hash
  done < "$out/release/checksums.txt"
}

################################################################################
# Downloads each listed package; rejects the release when one isn't attached or its sha256
# doesn't match.
################################################################################
fetch_packages() {
  local name id got reasons=()
  for name in "${!want[@]}"; do
    # GitHub renames "~" to "." in asset names.
    id=$(jq -r --arg a "$name" --arg b "${name//\~/.}" \
      '[.[] | select(.name == $a or .name == $b)][0].id // empty' "$out/assets.json")
    if [[ -z $id ]]; then
      reasons+=("$name is listed in checksums.txt but not attached")
      continue
    fi
    github__fetch_asset "$repo" "$id" "$out/files/$name"
    got=$(sha256sum "$out/files/$name" | cut -d' ' -f1)
    [[ $got == "${want[$name]}" ]] || reasons+=("$name: sha256 $got doesn't match checksums.txt")
  done
  [[ ${#reasons[@]} -eq 0 ]] || finish rejected "${reasons[@]}"
}

################################################################################
# Reads each package's metadata into infos (a JSON array, with its sha256), dropping packages of
# architectures the distributor doesn't publish.
################################################################################
read_packages() {
  local name info arch
  infos='[]'
  for name in "${!want[@]}"; do
    info=$(package__info "$out/files/$name") || log__fatal "can't read package metadata: $name"
    arch=$(jq -r .arch <<< "$info")
    if ! package__is_supported_arch "$(jq -r .format <<< "$info")" "$arch"; then
      log__info "admit: ignoring $name (architecture $arch)"
      rm -f "$out/files/$name"
      continue
    fi
    infos=$(jq -c --argjson i "$info" --arg sha "${want[$name]}" '. + [$i + {sha256: $sha}]' \
      <<< "$infos")
  done
}

################################################################################
# Skips the release quietly when any package has a prerelease version.
################################################################################
check_prerelease() {
  if base__jq -e 'import "version" as version; any(.version | version::is_prerelease)' \
    <<< "$infos" > /dev/null; then
    rm -rf "$out/files"
    finish skipped "prerelease version"
  fi
}

################################################################################
# The packages whose version isn't major.minor.patch.
# Outputs:
#   A reason per package on stdout.
################################################################################
version_reasons() {
  base__jq -r 'import "version" as version; .[] | select(.version | version::is_release | not)
    | "\(.filename): version \(.version) isn'"'"'t major.minor.patch"' <<< "$infos"
}

################################################################################
# The packages with the name, duplicate, and already-admitted rules applied. State goes to jq
# on stdin: it outgrows the command-line argument limit.
# Outputs:
#   The packages as JSON on stdout, each with its reasons ([] when it passes).
################################################################################
apply_package_rules() {
  state__json | base__jq -c --arg repo "$repo" --argjson cfg "$cfg" --argjson infos "$infos" \
    'import "admit" as admit; . as $state | $infos | admit::check($state; $cfg; $repo)'
}

################################################################################
# Rejects the release on any version or package rule; else admits its packages.
################################################################################
check_packages() {
  local reasons checked
  mapfile -t reasons < <(version_reasons)
  checked=$(apply_package_rules)
  mapfile -t -O "${#reasons[@]}" reasons < <(jq -r '.[].reasons[]' <<< "$checked")
  [[ ${#reasons[@]} -eq 0 ]] || finish rejected "${reasons[@]}"
  set_result '.packages = [$c[] | del(.reasons)
    + {path: "files/\(.filename)", status: "published"}]' --argjson c "$checked"
  finish published
}

declare -A want=()
infos='[]'

fetch_sidecars
check_publisher
verify_chain
check_denied_key
read_checksums
fetch_packages
read_packages
check_prerelease
check_packages
