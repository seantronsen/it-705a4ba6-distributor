# shellcheck shell=bash
# Case results. Source it after common.sh. A case script defines case_main and ends with
# pass/fail/error/skip through its exit code:
#   0 pass   1 fail (the distributor misbehaved)   2 error (GitHub or setup)   3 skip
# The message goes to $RUN/results/<case>.msg, for the report.

fail_case() { # <message>
  printf '%s\n' "$*" > "$RUN/results/$CASE.msg"
  log "FAIL: $*"
  exit 1
}

skip_case() { # <message>
  printf '%s\n' "$*" > "$RUN/results/$CASE.msg"
  log "SKIP: $*"
  exit 3
}

# Fails the case unless <cmd> succeeds. GitHub's state and status APIs lag, so a failed check
# is read again a few times before it counts.
check() { # <description> <cmd...>
  local desc=$1 try
  shift
  for try in 1 2 3; do
    if "$@"; then
      log "ok: $desc"
      return 0
    fi
    ((try < 3)) && sleep 10
  done
  fail_case "$desc"
}

# Asks the launcher to install <package> from a downloaded target, after this container exits
# (dnf from <dir>/rpm, apt from <dir>/deb).
client_check() { # <dir under $OUT> <package>
  mkdir -p "$RUN/client"
  printf '%s\t%s\n' "$1" "$2" >> "$RUN/client/$CASE"
}
