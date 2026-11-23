# discover.sh: releases not yet in state.

# $repo's published, non-prerelease releases ($releases, from lib.sh's releases_list) that state
# (input) has no entry for: {repo, tag, published_at} each.
def new($repo; $releases):
  . as $state
  | $releases[] | select((.draft or .prerelease) | not)
  | {repo: $repo, tag: .tag_name, published_at}
  | select($state["\(.repo)@\(.tag)"] == null);
