# The config's publishers ($pubs), keyed by GitHub user ID, against a tag's push actors (input:
# [{run, attempt, role, login, id, type}], from github__tag_push_actors).

# Whether GitHub user $id may publish $repo's releases. A username can be renamed and then
# registered by someone else, an ID can't. No entry: no. An entry without `repos` (core
# maintainers): any repo. With `repos`: only those.
def may_publish($pubs; $id; $repo):
  ($repo | ascii_downcase) as $r
  | $pubs["\($id)"] as $p
  | $p != null and ($p.repos == null or any($p.repos[]; ascii_downcase == $r));

# A reason per actor who may not publish $repo, naming their roles and runs.
def rejections($pubs; $repo):
  map(select(may_publish($pubs; .id; $repo) | not)) | group_by(.id)[]
  | "\(.[0].login // "unknown") (id \(.[0].id // "none"), \(.[0].type // "unknown")) may not"
    + " publish \($repo) (\(map(.role) | unique | join(", ")):"
    + " \(map("run \(.run) attempt \(.attempt)") | unique | join(", ")))";

# A warning per listed publisher whose username has changed (usernames are labels only).
def renamed($pubs):
  unique_by(.id)[] | . as $x | $pubs["\($x.id)"] // empty
  | select((.username | ascii_downcase) != (($x.login // "") | ascii_downcase))
  | "warning: publisher \($x.id) is listed as \(.username) but is now \($x.login)";
