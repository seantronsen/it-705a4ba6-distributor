# admit.sh's package rules.

import "state" as state;

def short($r): $r | split("/") | last | ascii_downcase;
def claims($n; $s): $n == $s or ($n | startswith($s + "-"));

# The release's packages (input: [{format, name, version, arch, filename, ...}]) with the name,
# duplicate, and already-admitted rules applied: each gets `reasons` ([] when it passes).
# $state: state/state.json; $cfg: the repos, keyed by name; $repo: the release's repo.
def check($state; $cfg; $repo):
  short($repo) as $me
  | ($cfg[$repo].allow // []) as $allow
  | [$cfg | to_entries[] | select(.key != $repo) | {name: .key} + .value] as $others
  # Historical owners: the repos that published each name, from state.
  | ($state | state::owners) as $owners
  | ($state | state::known_packages) as $known
  | group_by([.format, .name, .version, .arch]) as $groups
  | map(. as $p
      | ($owners[$p.name] // []) as $o
      | [ (if ($o | length) > 0 then
             (if ($o | index($repo)) == null
              then "\($p.filename): \($p.name) is already published by \($o | join(", "))"
              else empty end)
           elif ($allow | index($p.name)) == null and (claims($p.name; $me) | not) then
             "\($p.filename): \($p.name) is not \($me) or \($me)-* and not in allow"
           elif any($others[]; ((.allow // []) | index($p.name)) != null) then
             "\($p.filename): \($p.name) is in another repo's allow"
           elif any($others[]; (short(.name) | length) > ($me | length)
               and claims($p.name; short(.name))) then
             "\($p.filename): \($p.name) belongs to a repo with a longer matching name"
           else empty end),
          (if any($groups[]; length > 1 and .[0].format == $p.format and .[0].name == $p.name
               and .[0].version == $p.version and .[0].arch == $p.arch)
           then "\($p.filename): duplicate \($p.format) package \($p.name) \($p.version)"
             + " \($p.arch) in the release"
           else empty end),
          # A version is admitted once; a fix ships as a new patch version.
          (if any($known[]; .format == $p.format and .name == $p.name and .version == $p.version
               and .arch == $p.arch)
           then "\($p.filename): \($p.name) \($p.version) \($p.arch) was already admitted;"
             + " ship a new patch version"
           else empty end)
        ] as $why
      | $p + {reasons: ($why | unique)});
