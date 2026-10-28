# shellcheck shell=bash
# Service repo releases: real ones through the testbed's release pipeline, and crafted ones this
# suite builds and signs itself. Source it after common.sh and poll.sh.

# --- Real releases (testbed) --------------------------------------------------------------------

# Tags a new empty commit, so every tag is the only one on its commit (GoReleaser builds the
# highest tag on HEAD: github-actions#59), and pushes it; the testbed's release workflow runs.
tag_release() { # <tag>
  local dir=tag-$1
  clone_main "$T" "$dir"
  commit_all "$WORK/$dir" "it: $1"
  push_main "$WORK/$dir"
  git -C "$WORK/$dir" tag "$1"
  git -C "$WORK/$dir" push --quiet origin "refs/tags/$1"
  log "tagged $T $1"
}

# 0 once the release is published; aborts the wait if its release run failed.
release_published() { # <owner/repo> <tag>
  local conclusion
  if [[ $(gh release view "$2" -R "$1" --json isDraft -q .isDraft 2> /dev/null) == false ]]; then
    return 0
  fi
  conclusion=$(gh api "repos/$1/actions/runs?event=push&branch=$2" \
    -q '[.workflow_runs[] | select(.name == "release")][0].conclusion // empty')
  case $conclusion in
    failure | cancelled | timed_out) log "release run for $2: $conclusion"; return 3 ;;
  esac
  return 1
}

# Makes sure a testbed tag is published and admitted, tagging and polling only as needed.
ensure_published() { # <tag>
  [[ $(release_status "$T" "$1") == published ]] && return 0
  gh release view "$1" -R "$T" > /dev/null 2>&1 || tag_release "$1"
  wait_for "$T $1 released" release_published "$T" "$1" || exit 2
  poll_once > /dev/null
  [[ $(release_status "$T" "$1") == published ]] \
    || fail_case "setup: $T $1 wasn't published ($(release_status "$T" "$1"))"
}

# --- Crafted releases -------------------------------------------------------------------------

# Builds a minimal arch-independent deb in <dir> and prints its file name.
craft_deb() { # <dir> <name> <version> [revision]
  local dir=$1 name=$2 version=$3 rev=${4:-1} pkg
  pkg=$(mktemp -d "$WORK/deb.XXXX")
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/share/doc/$name"
  cat > "$pkg/DEBIAN/control" << EOF
Package: $name
Version: $version-$rev
Architecture: all
Maintainer: distributor-it <it@invalid>
Description: distributor integration test package
EOF
  echo "distributor-it" > "$pkg/usr/share/doc/$name/README"
  dpkg-deb --root-owner-group -Zgzip --build "$pkg" "$dir/${name}_${version}-${rev}_all.deb" \
    > /dev/null
  echo "${name}_${version}-${rev}_all.deb"
}

# Signs <dir>/checksums.txt the way gpg-sign-artifacts does and adds the three public keys:
# a 1-day signing key, certified by the repo's key ("repo") or by nobody ("foreign").
sign_dir() { # <dir> <owner/repo> <repo key fpr> <repo|foreign>
  local dir=$1 repo=$2 repo_fpr=$3 how=$4 signing
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  signing=$(key_new "$repo Release (distributor-it) <it@invalid>" ed25519 sign 1d)
  [[ -n $signing ]] || die "signing key generation failed"
  [[ $how == repo ]] && certify "$repo_fpr" "$signing"
  gpg --batch --yes --armor --local-user "$signing" --detach-sign \
    -o "$dir/checksums.txt.asc" "$dir/checksums.txt"
  gpg --armor --export "$signing" > "$dir/pubkey-signing.asc"
  gpg --armor --export "$repo_fpr" > "$dir/pubkey-repo.asc"
  gpg --armor --export "$ROOT_FPR" > "$dir/pubkey-org.asc"
}

# Publishes a release of crafted packages, signed through the run's key chain.
craft_release() { # <owner/repo> <tag> <deb spec>... (each "name version [revision]")
  local repo=$1 tag=$2 dir spec repo_fpr
  shift 2
  dir=$WORK/rel-$tag
  mkdir -p "$dir"
  for spec in "$@"; do
    # shellcheck disable=SC2086 # intentional word splitting
    craft_deb "$dir" $spec > /dev/null
  done
  (cd "$dir" && sha256sum -- *.deb > checksums.txt)
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  if [[ $repo == "$T" ]]; then repo_fpr=$TESTBED_FPR; else repo_fpr=$SERVICE2_FPR; fi
  sign_dir "$dir" "$repo" "$repo_fpr" repo
  release_create "$repo" "$tag" "$dir"/*
}

# Copies a testbed release's assets to a new non-v* tag (the release workflow ignores it);
# "badsig" re-signs checksums.txt with a key nothing certified.
release_copy() { # <from tag> <to tag> [badsig]
  local dir=$WORK/copy-$2
  # shellcheck source=/dev/null
  source "$RUN/run.env"
  mkdir -p "$dir"
  gh release download "$1" -R "$T" -D "$dir"
  [[ ${3:-} == badsig ]] && sign_dir "$dir" "$T" "$TESTBED_FPR" foreign
  release_create "$T" "$2" "$dir"/*
}

release_create() { # <owner/repo> <tag> [file...]
  gh release create "$2" -R "$1" --target main --title "$2" --notes "distributor-it" \
    --latest=false "${@:3}" > /dev/null
  log "released $1 $2 ($(($# - 2)) files)"
}

# Deletes a crafted release and its tag once polled, so it can't confuse later tag lookups.
release_drop() { # <owner/repo> <tag>
  gh release delete "$2" -R "$1" --cleanup-tag --yes
}
