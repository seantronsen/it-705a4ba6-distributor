#!/usr/bin/env bash
# Creates the suite's three throwaway repos under your GitHub account and records them in
# repos.yaml (gitignored), which run.sh and destroy.sh read:
#
#   it-<random>-distributor     the distributor
#   it-<random>-testbed         the testbed
#   it-<random>-testbed-tools   the second service repo (its name starts with the testbed's)
#
# They're public and empty; run.sh fills them. Delete them with destroy.sh.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/lib/log.sh"
source "$HERE/lib/config.sh"

main() {
  local file owner base try name taken
  file=$(config__repos_file)
  [[ ! -e $file ]] || log__die "$file exists: the repos are already made (destroy.sh first)"
  owner=$(gh api user -q .login) || log__die "gh isn't logged in (gh auth login)"

  # A taken name is practically impossible; pick a new one a few times anyway.
  for try in 1 2 3; do
    base=it-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    taken=false
    for name in "$base-distributor" "$base-testbed" "$base-testbed-tools"; do
      if gh api "repos/$owner/$name" > /dev/null 2>&1; then taken=true; fi
    done
    $taken || break
    log__info "$base is taken (try $try)"
  done
  $taken && log__die "couldn't find a free name"

  # Recorded first, so a failure part way still leaves destroy.sh the list.
  cat > "$file" << EOF
# Written by init.sh; read by run.sh and destroy.sh.
distributor: $owner/$base-distributor
testbed: $owner/$base-testbed
service2: $owner/$base-testbed-tools
EOF
  for name in "$base-distributor" "$base-testbed" "$base-testbed-tools"; do
    gh repo create "$owner/$name" --public \
      --description "distributor integration test repo (throwaway)" > /dev/null ||
      log__die "can't create $owner/$name"
    log__info "created $owner/$name"
  done
  log__info "recorded in $file"
}

main "$@"
