# prune.sh: what the target should hold.

import "state" as state;

# The target paths of $fmt's published packages (input: state), one per output.
def published_paths($fmt):
  state::published_packages[] | select(.format == $fmt)
  | if $fmt == "rpm" then "rpm/packages/\(.filename)"
    else "deb/pool/main/\(.name[0:1])/\(.name)/\(.filename)" end;
