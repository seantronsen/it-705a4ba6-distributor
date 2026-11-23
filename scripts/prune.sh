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
source "$(dirname "$0")/lib.sh"
source "$ROOT/scripts/lib-repo.sh"

[[ $# -eq 2 ]] || die "usage: prune.sh <rpm|deb> <outdir>"
fmt=$1 out=$2
[[ $fmt == rpm || $fmt == deb ]] || die "unknown format: $fmt"
mkdir -p "$out"
out=$(cd "$out" && pwd)

cfg=$(config_get .repos)
state=$(state_json)

# This format's published packages admitted with a denied repo key, as JSON:
# [{release, repo, format, name, filename, fingerprint}]
denied_packages() {
  jql -c --argjson cfg "$cfg" --arg fmt "$fmt" \
    'import "deny" as deny; deny::packages($cfg) | map(select(.format == $fmt))' <<< "$state"
}

# This format's other published packages that retention drops, as JSON.
retention_packages() { # <denied>
  jql -c --argjson cfg "$cfg" --arg fmt "$fmt" --argjson denied "$1" '
    import "state" as state; import "retention" as retention;
    state::published_packages | map(select(.format == $fmt)
      | select(. as $p | $denied | any(.release == $p.release and .filename == $p.filename) | not))
    | retention::apply($cfg) | map(select(.keep | not))' <<< "$state"
}

# Writes the delta for record: a pruned patch per package, and the denied ones for their issues.
write_delta() { # <pruned> <denied>
  jq -n --arg fmt "$fmt" --argjson pruned "$1" --argjson denied "$2" '
    {format: $fmt,
     patches: ([$pruned[] | {release, filename, status: "pruned", reason: "retention"}]
       + [$denied[]
          | {release, filename, status: "pruned", reason: "denied repo key \(.fingerprint)"}]),
     denied: $denied}' > "$out/prune-$fmt.json"
}

# Package files on the target that state doesn't list as published, one path per line.
orphan_paths() {
  local pkgdir
  if [[ $fmt == rpm ]]; then pkgdir=rpm/packages; else pkgdir=deb/pool; fi
  comm -23 <(target_find "$pkgdir" | sort) <(jql -r --arg fmt "$fmt" \
    'import "prune" as prune; prune::published_paths($fmt)' <<< "$state" | sort)
}

# The files to leave out of the metadata, one per line: rpm file names, or deb paths under deb/.
excludes() { # <remove> [orphan path]...
  local remove=$1 name filename f
  shift
  while IFS=$'\t' read -r name filename; do
    if [[ $fmt == rpm ]]; then
      echo "$filename"
    else
      f=$(package_path deb "$name" "$filename")
      echo "${f#*/}"
    fi
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$remove")
  for f in "$@"; do
    if [[ $fmt == rpm ]]; then echo "${f##*/}"; else echo "${f#deb/}"; fi
  done
}

# Rewrites the repository metadata without the excluded files.
rewrite_metadata() { # <excludes file>
  local work meta
  work=$(mktemp -d)
  if [[ $fmt == rpm ]]; then
    meta=$(rpm_metadata "$work" "$work/new" "$1")
    rpm_metadata_write "$meta"
  else
    meta=$(apt_metadata "$work" "$work/new" "$1")
    apt_metadata_write "$meta"
  fi
}

# Deletes the removed packages' files and the orphans from the target.
delete_files() { # <remove> [orphan path]...
  local remove=$1 name filename f
  shift
  while IFS=$'\t' read -r name filename; do
    target_rm "$(package_path "$fmt" "$name" "$filename")"
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$remove")
  for f in "$@"; do target_rm "$f"; done
}

denied=$(denied_packages)
pruned=$(retention_packages "$denied")
write_delta "$pruned" "$denied"
remove=$(jq -c -s 'add' <<< "$pruned $denied")

target_init
mapfile -t orphans < <(orphan_paths)
if [[ $(jq length <<< "$remove") -eq 0 && ${#orphans[@]} -eq 0 ]]; then
  log "prune $fmt: nothing to remove"
  exit 0
fi
log "prune $fmt: $(jq length <<< "$pruned") by retention, $(jq length <<< "$denied") for a denied" \
  "repo key, ${#orphans[@]} not in state"

archive_key_init
excludes_file=$(mktemp)
excludes "$remove" "${orphans[@]}" > "$excludes_file"
# Metadata first, then deletes, so metadata never points at a missing file.
rewrite_metadata "$excludes_file"
delete_files "$remove" "${orphans[@]}"

log "prune $fmt: done ($(target_url))"
