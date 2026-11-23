# publish.sh: the packages to publish.

# $fmt's packages from an admit dir's result.json ($r) when it was admitted, each with its
# release key and its file's path under $dir.
def admitted($r; $fmt; $dir):
  [$r | select(.status == "published") | .key as $k
   | .packages[] | select(.format == $fmt)
   | . + {release: $k, path: "\($dir)/\(.path)"}];
