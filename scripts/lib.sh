# shellcheck shell=bash
# Shared helpers for the distributor scripts. Source it; don't run it.
#
# Environment (all optional unless a script says otherwise):
#   CONFIG                 config file (default config/repos.yaml)
#   STATE                  state file (default state/state.json)
#   GITHUB_TOKEN           gh's token for the GitHub API (releases, assets, runs, issues)
#   PUBLISH_DIR            local publish target, used when the config sets no `target`
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials for the config's `target.s3`
#   ARCHIVE_GPG_KEY        archive secret key, armored or base64 (default, local target only:
#                          throwaway key)
#   ARCHIVE_GPG_PASSPHRASE its passphrase, if any
#   MASTER_PUBLIC_ASC, MASTER_FPR   root public key and fingerprint (admit)

set -euo pipefail
# set -e in $(...) too: e.g. a signing failure inside meta=$(rpm_metadata ...) fails the script
# instead of publishing an empty signature.
shopt -s inherit_errexit

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-$ROOT/config/repos.yaml}
STATE=${STATE:-$ROOT/state/state.json}
# shellcheck disable=SC2034 # used by the scripts that source this
{
  SUITE=stable
  DEB_ARCHES=(amd64 arm64)
  # github-actions' trust-chain check, pinned by commit; Renovate updates the tag and commit.
  # renovate: datasource=github-tags depName=OpenCHAMI/github-actions currentValue=v4.0.0
  VERIFY_CHAIN_URL=https://raw.githubusercontent.com/OpenCHAMI/github-actions/ec67a926c858892c2e5e18fed111d7a7720384f3/scripts/gpg-verify-trust-chain.sh
}

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

run_url() { echo "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"; }

# jq with the modules in scripts/jq/ available, e.g. `import "state" as state;`.
jql() { jq -L "$ROOT/scripts/jq" "$@"; }

# Whether a config setting is set.
config_has() { # <jq path>
  yq -o=json -I=0 . "$CONFIG" | jq -e "$1 != null" > /dev/null
}

# One config setting: scalars raw, objects and arrays as JSON. Dies when it isn't set: the
# schema says what's required, so the scripts carry no defaults.
config_get() { # <jq path>, e.g. .repos or .target.s3.bucket
  yq -o=json -I=0 . "$CONFIG" \
    | jq -r "$1"' | if . == null then error("unset") elif type == "object" or type == "array"
        then tojson else . end' 2> /dev/null \
    || die "config: $1 isn't set"
}

state_json() {
  if [[ -s $STATE ]]; then cat "$STATE"; else echo '{}'; fi
}

# --- GitHub API -------------------------------------------------------------------------------

uri() { jq -rn --arg s "$1" '$s | @uri'; }

# Releases of a repo as a JSON array of {tag_name, draft, prerelease, published_at}.
releases_list() { # <owner/repo>
  gh api --paginate "repos/$1/releases?per_page=100" \
    --jq '.[] | {tag_name, draft, prerelease, published_at}' | jq -s -c .
}

# A release's assets as a JSON array of {name, id}.
release_assets() { # <owner/repo> <tag>
  gh api "repos/$1/releases/tags/$(uri "$2")" | jq -c '[.assets[] | {name, id}]'
}

# Who pushed and who ran a tag's push runs, as a JSON array of
# {run, attempt, role, login, id, type}: each run's actor (role "pushed") and the triggering
# actor of each of its attempts (role "ran"). A re-run replaces the run's triggering actor, so
# earlier attempts are read one by one. Runs match by head_branch, so pushes to a branch with
# the tag's name count too. Returns 1 on any API failure (set -e is off when it's called from a
# condition), so a failed call is an infrastructure error, never an empty list.
tag_push_actors() { # <owner/repo> <tag>
  local repo=$1 tag=$2 runs reruns run count n
  runs=$(gh api --paginate "repos/$repo/actions/runs?event=push&branch=$(uri "$tag")&per_page=100" \
      --jq '.workflow_runs[]' \
    | jq -c --arg t "$tag" 'select(.event == "push" and .head_branch == $t)
        | {run: .id, attempt: .run_attempt, actor, triggering_actor}') || return 1
  reruns=$(jq -r 'select(.attempt > 1) | "\(.run) \(.attempt)"' <<< "$runs") || return 1
  {
    jq -c '{run, attempt} as $r
      | (.actor | {login, id, type} + $r + {role: "pushed"}),
        (.triggering_actor | {login, id, type} + $r + {role: "ran"})' <<< "$runs" || return 1
    while read -r run count; do
      for ((n = 1; n < count; n++)); do
        gh api "repos/$repo/actions/runs/$run/attempts/$n" \
          --jq '{run: .id, attempt: .run_attempt, role: "ran"} + (.triggering_actor | {login, id, type})' \
          || return 1
      done
    done <<< "$reruns"
  } | jq -s -c .
}

asset_fetch() { # <owner/repo> <asset-id> <dest>
  gh api -H 'Accept: application/octet-stream' "repos/$1/releases/assets/$2" > "$3"
}

# Open an issue with this title and label, unless an open one already exists.
issue_ensure() { # <title> <label> <body>
  local title=$1 label=$2 body=$3 number
  number=$(gh api "repos/$GITHUB_REPOSITORY/issues?state=open&labels=$(uri "$label")&per_page=100" \
    | jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty')
  if [[ -n $number ]]; then
    log "issue #$number already open: $title"
    return
  fi
  issue_create "$title" "$label" "$body"
}

# Close the open issue with this title and label, if any.
issue_close() { # <title> <label> <comment>
  local number
  number=$(gh api "repos/$GITHUB_REPOSITORY/issues?state=open&labels=$(uri "$2")&per_page=100" \
    | jq -r --arg t "$1" '[.[] | select(.title == $t)][0].number // empty')
  [[ -n $number ]] || return 0
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$number/comments" -f body="$3" > /dev/null
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/$number" -f state=closed > /dev/null
}

issue_create() { # <title> <label> <body>
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues" -f title="$1" -f body="$3" -f "labels[]=$2" \
    > /dev/null
}

# --- Publish target ---------------------------------------------------------------------------

# The target is the config's `target.s3` bucket, or else the local directory PUBLISH_DIR.
# Checks it's usable before anything is written.
target_init() {
  if target_is_s3; then
    # A throwaway key on a real target would publish packages nobody can verify.
    [[ -n ${ARCHIVE_GPG_KEY:-} ]] || die "target.s3 is set, so ARCHIVE_GPG_KEY is required"
  else
    mkdir -p "${PUBLISH_DIR:?PUBLISH_DIR is required without target.s3}"
  fi
}

target_is_s3() { config_has .target.s3; }

# The target's location, for logs and the aws CLI: s3://<bucket> or the PUBLISH_DIR path.
target_url() {
  if target_is_s3; then echo "s3://$(config_get .target.s3.bucket)"; else echo "$PUBLISH_DIR"; fi
}

s3() {
  local endpoint=()
  if config_has .target.s3.endpoint; then
    endpoint=(--endpoint-url "$(config_get .target.s3.endpoint)")
  fi
  aws --region "$(config_get .target.s3.region)" "${endpoint[@]}" "$@"
}

# Packages never change; metadata and keys do, so caches (a CDN) refetch them after
# target.s3.metadata-max-age seconds.
cache_control() { # <path>
  case $1 in
    rpm/packages/* | deb/pool/*) echo 'public,max-age=31536000,immutable' ;;
    *) echo "public,max-age=$(config_get '.target.s3["metadata-max-age"]'),must-revalidate" ;;
  esac
}

# 1 when absent; dies on any other error, since "absent" makes publish rebuild the metadata from
# scratch. On S3, absence reads as NoSuchKey only with s3:ListBucket (else AccessDenied).
target_get() { # <path> <dest>
  local err
  mkdir -p "$(dirname "$2")"
  if ! target_is_s3; then
    [[ -f $PUBLISH_DIR/$1 ]] || return 1
    cp "$PUBLISH_DIR/$1" "$2"
  elif ! err=$(s3 s3api get-object --bucket "$(config_get .target.s3.bucket)" --key "$1" "$2" \
    2>&1 > /dev/null); then
    [[ $err == *NoSuchKey* ]] && return 1
    die "can't read $(target_url)/$1: $err"
  fi
}

target_put() { # <src> <path>; atomic per file
  if target_is_s3; then
    s3 s3 cp --only-show-errors --cache-control "$(cache_control "$2")" "$1" "$(target_url)/$2"
    return
  fi
  local dest=$PUBLISH_DIR/$2
  mkdir -p "$(dirname "$dest")"
  cp "$1" "$dest.tmp.$$"
  mv -f "$dest.tmp.$$" "$dest"
}

target_rm() { # <path>
  if target_is_s3; then
    s3 s3 rm --only-show-errors "$(target_url)/$1"
  else
    rm -f "$PUBLISH_DIR/$1"
  fi
}

target_ls() { # <dir>: file names directly in it
  if target_is_s3; then
    s3 s3api list-objects-v2 --bucket "$(config_get .target.s3.bucket)" --prefix "$1/" \
      --delimiter / --output json \
      | jq -r --arg p "$1/" '(.Contents // [])[].Key | ltrimstr($p)'
    return
  fi
  [[ -d $PUBLISH_DIR/$1 ]] || return 0
  find "$PUBLISH_DIR/$1" -maxdepth 1 -type f ! -name '*.tmp.*' -printf '%f\n'
}

target_find() { # <dir>: paths of every file under it, from the target root
  if target_is_s3; then
    s3 s3api list-objects-v2 --bucket "$(config_get .target.s3.bucket)" --prefix "$1/" \
      --output json \
      | jq -r '(.Contents // [])[].Key'
    return
  fi
  [[ -d $PUBLISH_DIR/$1 ]] || return 0
  (cd "$PUBLISH_DIR" && find "$1" -type f ! -name '*.tmp.*')
}

# --- Archive key ------------------------------------------------------------------------------

# Sets up a private GNUPGHOME holding the archive secret key. Sets ARCHIVE_FPR and ARCHIVE_PUB (the
# exported public key). Without ARCHIVE_GPG_KEY it generates a throwaway key.
archive_key_init() {
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  chmod 700 "$GNUPGHOME"
  printf 'pinentry-mode loopback\ntrust-model always\n' > "$GNUPGHOME/gpg.conf"
  if [[ -n ${ARCHIVE_GPG_PASSPHRASE:-} ]]; then
    printf '%s' "$ARCHIVE_GPG_PASSPHRASE" > "$GNUPGHOME/passphrase"
    echo "passphrase-file $GNUPGHOME/passphrase" >> "$GNUPGHOME/gpg.conf"
  fi

  if [[ -n ${ARCHIVE_GPG_KEY:-} ]]; then
    if grep -q 'BEGIN PGP' <<< "$ARCHIVE_GPG_KEY"; then
      printf '%s\n' "$ARCHIVE_GPG_KEY"
    else
      base64 -d <<< "$ARCHIVE_GPG_KEY"
    fi | gpg --batch --quiet --import 2> /dev/null || die "ARCHIVE_GPG_KEY doesn't import"
  else
    gpg --batch --quiet --passphrase '' --quick-generate-key \
      'OpenCHAMI throwaway archive key' rsa3072 sign 1y 2> /dev/null
    log "ARCHIVE_GPG_KEY not set: signing with a throwaway archive key"
  fi

  local fprs
  fprs=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="sec" {s=1} s && $1=="fpr" {print $10; s=0}')
  [[ $(wc -l <<< "$fprs") -eq 1 && -n $fprs ]] || die "the archive key must be exactly one secret key"
  ARCHIVE_FPR=$fprs
  ARCHIVE_PUB=$GNUPGHOME/archive-public.asc
  gpg --batch --armor --export "$ARCHIVE_FPR" > "$ARCHIVE_PUB"
  export ARCHIVE_FPR ARCHIVE_PUB

  # A real key must be the committed one (keys/archive.asc), e.g. not half through a switch.
  if [[ -n ${ARCHIVE_GPG_KEY:-} && -f $ROOT/keys/archive.asc ]]; then
    [[ $(key_file_fpr "$ROOT/keys/archive.asc") == "$ARCHIVE_FPR" ]] \
      || die "ARCHIVE_GPG_KEY ($ARCHIVE_FPR) isn't keys/archive.asc"
  fi
}

key_file_fpr() { # <armored public key file>: its primary key's fingerprint
  gpg --batch --with-colons --show-keys "$1" 2> /dev/null | awk -F: '$1=="fpr" {print $10; exit}'
}

rpm_resign() { # <rpm>...: replaces any signature with the archive key's
  rpmsign --delsign "$@" > /dev/null
  rpm_sign "$@"
}

rpm_sign() { # <rpm>...
  # Ubuntu's rpm macros point __gpg at a path that may not exist; use the gpg on PATH.
  rpmsign --addsign --define "__gpg $(command -v gpg)" --define "_gpg_name $ARCHIVE_FPR" \
    --define "_gpg_path $GNUPGHOME" "$@" > /dev/null
}

# --- Packages ---------------------------------------------------------------------------------

# Metadata of a .rpm or .deb as JSON {format, name, version, arch, filename}; version is the
# upstream version (rpm VERSION; deb Version without epoch or revision).
package_info() { # <file>
  local f=$1 name version arch format
  case $f in
    *.rpm)
      format=rpm
      IFS=$'\t' read -r name version arch < <(rpm -qp --nosignature --nodigest \
        --qf '%{NAME}\t%{VERSION}\t%{ARCH}\n' "$f" 2> /dev/null)
      ;;
    *.deb)
      format=deb
      name=$(dpkg-deb -f "$f" Package)
      version=$(dpkg-deb -f "$f" Version)
      arch=$(dpkg-deb -f "$f" Architecture)
      version=${version#*:}
      [[ $version == *-* ]] && version=${version%-*}
      ;;
    *) die "not a package: $f" ;;
  esac
  jq -nc --arg format "$format" --arg name "$name" --arg version "$version" --arg arch "$arch" \
    --arg filename "$(basename "$f")" '{format: $format, name: $name, version: $version, arch: $arch, filename: $filename}'
}

supported_arch() { # <format> <arch>
  case $1:$2 in
    rpm:x86_64 | rpm:aarch64 | rpm:noarch | deb:amd64 | deb:arm64 | deb:all) return 0 ;;
    *) return 1 ;;
  esac
}

# Path of a package in the publish target.
package_path() { # <format> <name> <filename>
  case $1 in
    rpm) echo "rpm/packages/$3" ;;
    deb) echo "deb/pool/main/${2:0:1}/$2/$3" ;;
  esac
}
