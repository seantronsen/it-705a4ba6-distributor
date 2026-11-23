# Repo names: owner/repo, and release keys owner/repo@tag.

# "owner/repo" -> "repo", lowercased.
def short_name($repo): $repo | split("/") | last | ascii_downcase;

# A release key (input): "owner/repo@tag" -> "owner/repo".
def from_release_key: split("@")[0];

# Whether a package name is named after a repo: "<repo's short name>" or "<short name>-*".
def is_package_named_after($repo; $name):
  short_name($repo) as $s | $name == $s or ($name | startswith($s + "-"));
