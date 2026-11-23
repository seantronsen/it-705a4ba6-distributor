#!/usr/bin/env bash
# Publish one format. Only adds: no retention, no denied keys.
#
#   publish.sh <rpm|deb> <outdir> [admit-dir...]
#
# Takes the admitted packages of that format from each admit dir's result.json, signs the rpms,
# writes the packages to the publish target, then merges them into the repository metadata.
# Writes <outdir>/delta-<format>.json for record.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/keys.sh"
source "$(dirname "$0")/lib/package.sh"
source "$(dirname "$0")/lib/repo.sh"
source "$(dirname "$0")/lib/target.sh"

[[ $# -ge 2 ]] || log__fatal "usage: publish.sh <rpm|deb> <outdir> [admit-dir...]"
fmt=$1 out=$2
shift 2
[[ $fmt == rpm || $fmt == deb ]] || log__fatal "unknown format: $fmt"
mkdir -p "$out"
out=$(cd "$out" && pwd)
delta=$out/delta-$fmt.json

new='[]'
for d in "$@"; do
  d=$(cd "$d" && pwd)
  new=$(base__jq -c --arg fmt "$fmt" --arg d "$d" --slurpfile r "$d/result.json" \
    'import "publish" as publish; . + publish::admitted($r[0]; $fmt; $d)' <<< "$new")
done

if [[ $(jq length <<< "$new") -eq 0 ]]; then
  jq -n --arg fmt "$fmt" '{format: $fmt, patches: []}' > "$delta"
  log__info "publish $fmt: nothing new"
  exit 0
fi
log__info "publish $fmt: $(jq length <<< "$new") new"

keys__init_archive

# rpms record the archive key that signed them, so rekey knows what to re-sign.
jq -n --arg fmt "$fmt" --arg fpr "$ARCHIVE_FPR" --argjson new "$new" '{format: $fmt, patches: [
  $new[] | {release, filename, status: "published"}
  + (if $fmt == "rpm" then {signed_with: $fpr} else {} end)]}' > "$delta"

work=$(mktemp -d)
newdir=$work/new
excludes=$work/excludes
# Drop existing metadata entries with the same filename as a new package, so a retried publish
# replaces them instead of duplicating them.
while IFS=$'\t' read -r name filename; do
  if [[ $fmt == rpm ]]; then
    echo "$filename"
  else
    rel=$(package__path deb "$name" "$filename")
    echo "${rel#*/}"
  fi
done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$new") > "$excludes"

while IFS=$'\t' read -r name filename path; do
  rel=$(package__path "$fmt" "$name" "$filename")
  dest=$newdir/${rel#*/}
  mkdir -p "$(dirname "$dest")"
  cp "$path" "$dest"
  [[ $fmt == rpm ]] && keys__sign_rpm "$dest"
done < <(jq -r '.[] | [.name, .filename, .path] | @tsv' <<< "$new")

if [[ $fmt == rpm ]]; then
  meta=$(repo__rpm_metadata "$work" "$newdir" "$excludes")
else
  meta=$(repo__apt_metadata "$work" "$newdir" "$excludes")
fi

# Packages first, then metadata, so metadata never points at a missing file. Package names are
# unique, so the writes run in parallel.
jq -r '.[] | [.name, .filename] | @tsv' <<< "$new" | while IFS=$'\t' read -r name filename; do
  rel=$(package__path "$fmt" "$name" "$filename")
  printf '%s\0%s\0' "$newdir/${rel#*/}" "$rel"
done | xargs -0 -n 2 -P 8 bash -c 'source "$0"; target__put "$1" "$2"' "$ROOT/scripts/lib/target.sh"

if [[ $fmt == rpm ]]; then
  repo__write_rpm_metadata "$meta"
else
  repo__write_apt_metadata "$meta"
fi

keys__publish
log__info "publish $fmt: done ($(target__url))"
