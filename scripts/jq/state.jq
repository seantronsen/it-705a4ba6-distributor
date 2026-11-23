# state/state.json (input): releases keyed by <repo>@<tag>, each with its packages.

import "repo" as repo;

# Packages currently published, with their release key and repo:
# [{release, repo, format, name, version, arch, filename, sha256, repo_key, at, ...}]
def published_packages:
  [to_entries[] | .key as $rel | .value as $r
    | select($r.status == "published")
    | $r.packages[] | select(.status == "published")
    | . + {release: $rel, repo: ($rel | repo::from_release_key), repo_key: $r.repo_key,
        at: $r.at}];

# Packages still published whose repo key the config ($cfg: the repos, keyed by name) now
# denies (all, or those admitted at or after the entry's `since`): what prune removes next.
# [{release, repo, format, name, filename, fingerprint}]
def published_packages_with_denied_key($cfg):
  [published_packages[]
    | . as $p
    | (($cfg[$p.repo].deny // [])[]
        | select(.fingerprint == $p.repo_key)
        | select(.since == null or (($p.at | fromdateiso8601) >= (.since | fromdateiso8601))))
    | {release: $p.release, repo: $p.repo, format: $p.format, name: $p.name,
       filename: $p.filename, fingerprint}];

# The repos that have recorded each package name, in any status: {name: [repo]}.
def package_owners:
  [to_entries[] | .key as $k | .value.packages[] | {name, repo: ($k | repo::from_release_key)}]
  | group_by(.name) | map({key: .[0].name, value: (map(.repo) | unique)}) | from_entries;

# Applies one delta ($d) to state (input): an admit result.json writes its release entry (new or
# replacing it); a publish, prune, or rekey delta patches package entries in existing releases.
def apply_delta($d):
  if $d.key then
    .[$d.key] = ($d | {status, at, run}
      + (if .status == "published" then {repo_key, packages: [.packages[] | del(.path)]}
         else {reasons, packages: []} end))
  else
    reduce $d.patches[] as $p (.;
      if .[$p.release] == null then .
      else .[$p.release].packages |= map(
        if .filename == $p.filename then . + ($p | del(.release, .filename)) else . end)
      end)
  end;
