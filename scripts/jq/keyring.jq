# keyring.sh: the keyring's version.

import "version" as version;

# The next version (input: state): the latest <$name>@<version> with the patch bumped, or 1.0.0.
def next_version($name):
  [keys[] | select(startswith("\($name)@")) | ltrimstr("\($name)@") | version::parse]
  | (max // [1, 0, -1]) | "\(.[0]).\(.[1]).\(.[2] + 1)";
