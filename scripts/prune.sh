#!/usr/bin/env bash
# Prune one format. Only removes.
#
#   prune.sh <rpm|deb> <outdir>
#
# Decides, from state, which published packages to remove: those admitted with a denied repo key,
# then the retention policy over the rest; plus any package file on the target that state
# doesn't list as published (left by a run that died mid-publish, or a state reset). Rewrites
# the repository metadata without them and deletes their files. Writes
# <outdir>/prune-<format>.json for record.
source "$(dirname "$0")/lib/base.sh"
source "$(dirname "$0")/lib/config.sh"
source "$(dirname "$0")/lib/keys.sh"
source "$(dirname "$0")/lib/package.sh"
source "$(dirname "$0")/lib/repo.sh"
source "$(dirname "$0")/lib/state.sh"
source "$(dirname "$0")/lib/target.sh"

[[ $# -eq 2 ]] || log__fatal "usage: prune.sh <rpm|deb> <outdir>"
fmt=$1 out=$2
[[ $fmt == rpm || $fmt == deb ]] || log__fatal "unknown format: $fmt"
mkdir -p "$out"
out=$(cd "$out" && pwd)

cfg=$(config__get .repos)
state=$(state__json)

################################################################################
# This format's published packages admitted with a denied repo key, as JSON:
# [{release, repo, format, name, filename, fingerprint}]
################################################################################
denied_packages() {
  base__jq -c --argjson cfg "$cfg" --arg fmt "$fmt" \
    'import "deny" as deny; deny::packages($cfg) | map(select(.format == $fmt))' <<< "$state"
}

################################################################################
# This format's other published packages that retention drops, as JSON.
# Arguments:
#   <denied>
################################################################################
retention_packages() {
  base__jq -c --argjson cfg "$cfg" --arg fmt "$fmt" --argjson denied "$1" '
    import "state" as state; import "retention" as retention;
    state::published_packages | map(select(.format == $fmt)
      | select(. as $p | $denied | any(.release == $p.release and .filename == $p.filename) | not))
    | retention::apply($cfg) | map(select(.keep | not))' <<< "$state"
}

################################################################################
# Writes the delta for record: a pruned patch per package, and the denied ones for their issues.
# Arguments:
#   <pruned> <denied>
################################################################################
write_delta() {
  jq -n --arg fmt "$fmt" --argjson pruned "$1" --argjson denied "$2" '
    {format: $fmt,
     patches: ([$pruned[] | {release, filename, status: "pruned", reason: "retention"}]
       + [$denied[]
          | {release, filename, status: "pruned", reason: "denied repo key \(.fingerprint)"}]),
     denied: $denied}' > "$out/prune-$fmt.json"
}

################################################################################
# Package files on the target that state doesn't list as published, one path per line.
################################################################################
orphan_paths() {
  local pkgdir
  if [[ $fmt == rpm ]]; then pkgdir=rpm/packages; else pkgdir=deb/pool; fi
  comm -23 <(target__find "$pkgdir" | sort) <(base__jq -r --arg fmt "$fmt" \
    'import "prune" as prune; prune::published_paths($fmt)' <<< "$state" | sort)
}

################################################################################
# The files to leave out of the metadata, one per line: rpm file names, or deb paths under deb/.
# Arguments:
#   <remove> [orphan path]...
################################################################################
excludes() {
  local remove=$1 name filename f
  shift
  while IFS=$'\t' read -r name filename; do
    if [[ $fmt == rpm ]]; then
      echo "$filename"
    else
      f=$(package__path deb "$name" "$filename")
      echo "${f#*/}"
    fi
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$remove")
  for f in "$@"; do
    if [[ $fmt == rpm ]]; then echo "${f##*/}"; else echo "${f#deb/}"; fi
  done
}

################################################################################
# Rewrites the repository metadata without the excluded files.
# Arguments:
#   <excludes file>
################################################################################
rewrite_metadata() {
  local work meta
  work=$(mktemp -d)
  if [[ $fmt == rpm ]]; then
    meta=$(repo__rpm_metadata "$work" "$work/new" "$1")
    repo__write_rpm_metadata "$meta"
  else
    meta=$(repo__apt_metadata "$work" "$work/new" "$1")
    repo__write_apt_metadata "$meta"
  fi
}

################################################################################
# Deletes the removed packages' files and the orphans from the target.
# Arguments:
#   <remove> [orphan path]...
################################################################################
delete_files() {
  local remove=$1 name filename f
  shift
  while IFS=$'\t' read -r name filename; do
    target__rm "$(package__path "$fmt" "$name" "$filename")"
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$remove")
  for f in "$@"; do target__rm "$f"; done
}

denied=$(denied_packages)
pruned=$(retention_packages "$denied")
write_delta "$pruned" "$denied"
remove=$(jq -c -s 'add' <<< "$pruned $denied")

mapfile -t orphans < <(orphan_paths)
if [[ $(jq length <<< "$remove") -eq 0 && ${#orphans[@]} -eq 0 ]]; then
  log__info "prune $fmt: nothing to remove"
  exit 0
fi
log__info "prune $fmt: $(jq length <<< "$pruned") by retention," \
  "$(jq length <<< "$denied") for a denied repo key, ${#orphans[@]} not in state"

keys__init_archive
excludes_file=$(mktemp)
excludes "$remove" "${orphans[@]}" > "$excludes_file"
# Metadata first, then deletes, so metadata never points at a missing file.
rewrite_metadata "$excludes_file"
delete_files "$remove" "${orphans[@]}"

log__info "prune $fmt: done ($(target__url))"
