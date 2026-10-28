# shellcheck shell=bash
# Case 11: dnf and apt install testbed from the target a poll published, with signatures
# checked. This container downloads the target; the launcher runs the client containers.

# The newest testbed release in state that still has published packages, and its admitting run.
latest_published() {
  state_get | jq -r --arg t "$T@" '
    [to_entries[]
     | select((.key | startswith($t)) and any(.value.packages[]?; .status == "published"))]
    | sort_by(.value.at) | last // empty | "\(.key) \(.value.run)"'
}

case_main() {
  local found release url run dir=case-11
  found=$(latest_published)
  if [[ -z $found ]]; then
    ensure_published v1.0.0
    found=$(latest_published)
  fi
  read -r release url <<< "$found"
  run=${url##*/}
  log "installing from $release (run $run)"
  echo "$run" >> "$RUN/results/$CASE.runs"
  rm -rf "${OUT:?}/$dir"
  gh run download "$run" -R "$D" -n target-publish-rpm -D "$OUT/$dir/rpm"
  gh run download "$run" -R "$D" -n target-publish-deb -D "$OUT/$dir/deb"
  check "the target carries the run's archive key" \
    test -s "$OUT/$dir/rpm/keys/archive.asc" -a -s "$OUT/$dir/deb/keys/archive.asc"
  client_check "$dir" testbed
}
