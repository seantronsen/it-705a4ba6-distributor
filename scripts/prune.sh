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

################################################################################
# A format's published packages admitted with a denied repo key.
# Arguments:
#   <rpm|deb>
# Outputs:
#   [{release, repo, format, name, filename, fingerprint}] as JSON on stdout.
################################################################################
denied_packages() {
  state__json | base__jq -c --argjson cfg "$(config__get .repos)" --arg fmt "$1" \
    'import "deny" as deny; deny::package_list($cfg) | map(select(.format == $fmt))'
}

################################################################################
# A format's other published packages that retention drops.
# Arguments:
#   <rpm|deb> <denied (denied_packages)>
# Outputs:
#   The packages as JSON on stdout.
################################################################################
retention_packages() {
  state__json | base__jq -c --argjson cfg "$(config__get .repos)" --arg fmt "$1" \
    --argjson denied "$2" '
    import "state" as state; import "retention" as retention;
    state::published_packages | map(select(.format == $fmt)
      | select(. as $p | $denied | any(.release == $p.release and .filename == $p.filename) | not))
    | retention::apply($cfg) | map(select(.keep | not))'
}

################################################################################
# Writes the delta for record: a pruned patch per package, and the denied ones for their issues.
# Arguments:
#   <rpm|deb> <outdir> <pruned (retention_packages)> <denied (denied_packages)>
################################################################################
write_delta() {
  jq -n --arg fmt "$1" --argjson pruned "$3" --argjson denied "$4" '
    {format: $fmt,
     patches: ([$pruned[] | {release, filename, status: "pruned", reason: "retention"}]
       + [$denied[]
          | {release, filename, status: "pruned", reason: "denied repo key \(.fingerprint)"}]),
     denied: $denied}' > "$2/prune-$1.json"
}

################################################################################
# A format's package files on the target that state doesn't list as published.
# Arguments:
#   <rpm|deb>
# Outputs:
#   Their paths on stdout, one per line.
################################################################################
orphan_paths() {
  local fmt=$1 pkgdir
  if [[ $fmt == rpm ]]; then pkgdir=rpm/packages; else pkgdir=deb/pool; fi
  comm -23 <(target__file_list_tree "$pkgdir" | sort) <(state__json | base__jq -r --arg fmt "$fmt" \
    'import "prune" as prune; prune::published_paths($fmt)' | sort)
}

################################################################################
# The files to leave out of the metadata: rpm file names, or deb paths under deb/.
# Arguments:
#   <rpm|deb> <remove (JSON)> [orphan path]...
# Outputs:
#   The files on stdout, one per line.
################################################################################
excludes() {
  local fmt=$1 remove=$2 name filename f
  shift 2
  while IFS=$'\t' read -r name filename; do
    if [[ $fmt == rpm ]]; then
      echo "$filename"
    else
      f=$(package__target_path deb "$name" "$filename")
      echo "${f#*/}"
    fi
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$remove")
  for f in "$@"; do
    if [[ $fmt == rpm ]]; then echo "${f##*/}"; else echo "${f#deb/}"; fi
  done
}

################################################################################
# Rewrites a format's repository metadata without the excluded files.
# Arguments:
#   <rpm|deb> <excludes file>
################################################################################
rewrite_metadata() {
  local fmt=$1 excludes=$2 work meta
  work=$(mktemp -d)
  if [[ $fmt == rpm ]]; then
    meta=$(repo__rpm_metadata_build "$work" "$work/new" "$excludes")
    repo__rpm_metadata_write "$meta"
  else
    meta=$(repo__apt_metadata_build "$work" "$work/new" "$excludes")
    repo__apt_metadata_write "$meta"
  fi
}

################################################################################
# Deletes the removed packages' files and the orphans from the target.
# Arguments:
#   <rpm|deb> <remove (JSON)> [orphan path]...
################################################################################
delete_files() {
  local fmt=$1 remove=$2 name filename f
  shift 2
  while IFS=$'\t' read -r name filename; do
    target__file_delete "$(package__target_path "$fmt" "$name" "$filename")"
  done < <(jq -r '.[] | [.name, .filename] | @tsv' <<< "$remove")
  for f in "$@"; do target__file_delete "$f"; done
}

################################################################################
# Prunes one format: decides what to remove, writes the delta, then rewrites the metadata
# without it before deleting the files, so metadata never points at a missing file.
# Arguments:
#   <rpm|deb> <outdir>
################################################################################
main() {
  local fmt=$1 out denied pruned remove excludes_file
  local -a orphans
  mkdir -p "$2"
  out=$(cd "$2" && pwd)
  denied=$(denied_packages "$fmt")
  pruned=$(retention_packages "$fmt" "$denied")
  write_delta "$fmt" "$out" "$pruned" "$denied"
  remove=$(jq -c -s 'add' <<< "$pruned $denied")

  mapfile -t orphans < <(orphan_paths "$fmt")
  if [[ $(jq length <<< "$remove") -eq 0 && ${#orphans[@]} -eq 0 ]]; then
    log__info "prune $fmt: nothing to remove"
    return
  fi
  log__info "prune $fmt: $(jq length <<< "$pruned") by retention," \
    "$(jq length <<< "$denied") for a denied repo key, ${#orphans[@]} not in state"

  keys__archive_load
  excludes_file=$(mktemp)
  excludes "$fmt" "$remove" "${orphans[@]}" > "$excludes_file"
  rewrite_metadata "$fmt" "$excludes_file"
  delete_files "$fmt" "$remove" "${orphans[@]}"
  log__info "prune $fmt: done ($(target__url))"
}

[[ $# -eq 2 ]] || log__fatal "usage: prune.sh <rpm|deb> <outdir>"
[[ $1 == rpm || $1 == deb ]] || log__fatal "unknown format: $1"
main "$@"
