# state/state.json (input): releases keyed by <repo>@<tag>, each with its packages.

# "owner/repo@tag" -> "owner/repo"
def repo_of: split("@")[0];

# Packages currently published, with their release key and repo:
# [{release, repo, format, name, version, arch, filename, sha256, repo_key, at, ...}]
def published_packages:
  [to_entries[] | .key as $rel | .value as $r
    | select($r.status == "published")
    | ($r.packages // [])[] | select(.status == "published")
    | . + {release: $rel, repo: ($rel | repo_of), repo_key: $r.repo_key, at: $r.at}];

# Every package state has recorded, in any status.
def known_packages: [to_entries[] | (.value.packages // [])[]];

# The repos that have published each package name: {name: [repo]}.
def owners:
  [to_entries[] | .key as $k | (.value.packages // [])[] | {name, repo: ($k | repo_of)}]
  | group_by(.name) | map({key: .[0].name, value: (map(.repo) | unique)}) | from_entries;
