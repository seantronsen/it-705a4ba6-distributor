# The config's `deny` entries ($cfg: the repos, keyed by name): revoked repo keys.

import "state" as state;

# Published packages admitted with a denied repo key (all, or admitted at or after `since`),
# from state (input): [{release, repo, format, name, filename, fingerprint}]
def package_list($cfg):
  [state::published_packages[]
    | . as $p
    | (($cfg[$p.repo].deny // [])[]
        | select(.fingerprint == $p.repo_key)
        | select(.since == null or (($p.at | fromdateiso8601) >= (.since | fromdateiso8601))))
    | {release: $p.release, repo: $p.repo, format: $p.format, name: $p.name,
       filename: $p.filename, fingerprint}];

# Why $repo's key $fpr is denied, or nothing when it isn't (input: $cfg).
def reason($repo; $fpr):
  first(.[$repo].deny[] | select(.fingerprint == $fpr) | .reason // "no reason given");
