# shellcheck shell=bash
# Shared helpers for the integration suite's container phases. Source it; don't run it.
#
# Environment (set by the launcher):
#   IT_DISTRIBUTOR_REPO, IT_TESTBED_REPO, IT_SERVICE2_REPO   throwaway repos (owner/name)
#   IT_TIMEOUT             seconds a wait may take before the case errors (default 3600)
#   IT_POLL_INTERVAL       seconds between checks while waiting (default 20)
#   GH_TOKEN               read from stdin by entry.sh; never from the environment

set -euo pipefail

# shellcheck disable=SC2034 # used by the files that source this
{
  RUN=/it-run   # shared by every phase of one run: keys, run.env, results (RAM-backed)
  OUT=/it-out   # kept after the run: report, logs, downloaded targets
  WORK=/work    # this container's tmpfs
  D=$IT_DISTRIBUTOR_REPO T=$IT_TESTBED_REPO S=$IT_SERVICE2_REPO
  MARKER=.distributor-it
}
IT_TIMEOUT=${IT_TIMEOUT:-3600}
IT_POLL_INTERVAL=${IT_POLL_INTERVAL:-20}
GNUPGHOME=$RUN/gnupg
export GNUPGHOME

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# The repo's lowercase name without its owner, as admit compares package names.
short() { local n=${1#*/}; echo "${n,,}"; }

# --- Waiting -----------------------------------------------------------------------------------

# Runs <cmd> every IT_POLL_INTERVAL seconds until it exits 0. Exit 1 means "not yet"; any other
# exit aborts the wait. Returns 0 when done, 2 on abort or timeout (GitHub didn't get there).
wait_for() { # <description> <cmd...>
  local desc=$1; shift
  local deadline=$((SECONDS + IT_TIMEOUT)) rc
  log "waiting: $desc"
  while :; do
    rc=0
    "$@" || rc=$?
    case $rc in
      0) log "done: $desc"; return 0 ;;
      1) ;;
      *) log "aborted: $desc"; return 2 ;;
    esac
    ((SECONDS < deadline)) || { log "timed out after ${IT_TIMEOUT}s: $desc"; return 2; }
    sleep "$IT_POLL_INTERVAL"
  done
}

# --- Git ---------------------------------------------------------------------------------------

# Clones a throwaway repo's main into $WORK/<dir> (depth 1), authenticated by GH_TOKEN.
clone_main() { # <owner/repo> <dir>
  rm -rf "${WORK:?}/$2"
  git clone --quiet --depth 1 "https://github.com/$1.git" "$WORK/$2"
}

commit_all() { # <dir> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=distributor-it -c user.email=it@invalid commit --quiet --allow-empty \
    -m "$2"
}

push_main() { # <dir> [--force]
  git -C "$1" push --quiet "${@:2}" origin HEAD:refs/heads/main
}

head_sha() { # <owner/repo>
  gh api "repos/$1/commits/main" -q .sha
}
