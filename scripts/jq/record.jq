# record.sh: applying a run's results to state, and the issues they open.

# Applies one result file ($d) to state (input): an admit result.json upserts its release entry;
# a publish, prune, or rekey delta patches package entries.
def apply($d):
  if $d.key then
    .[$d.key] = ($d | {status, at, run}
      + (if .status == "published" then {repo_key, packages: [.packages[] | del(.path)]}
         else {reasons} end))
  else
    reduce $d.patches[] as $p (.;
      if .[$p.release] == null then .
      else .[$p.release].packages |= map(
        if .filename == $p.filename then . + ($p | del(.release, .filename)) else . end)
      end)
  end;

# The body of a rejected release's issue (input: its result.json).
def rejection_body:
  "Release `\(.key)` was rejected, so none of its packages were published.\n\n"
  + (.reasons | map("- \(.)") | join("\n"))
  + "\n\nRun: \(.run)\n\nFix the problem and publish a new patch release; this release won't"
  + " be processed again.";

# The denied packages across delta files (input: the deltas, slurped), one group per repo and
# key.
def denial_groups: [.[].denied // [] | .[]] | group_by([.repo, .fingerprint])[];

# The body of a denied repo key's issue (input: one denial group).
def denial_body:
  "These packages were admitted with a denied repo key and have been unpublished:\n\n"
  + (map("- `\(.filename)` (\(.release))") | join("\n"));
