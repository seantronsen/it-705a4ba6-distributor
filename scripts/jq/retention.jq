# Retention ($cfg: the repos, keyed by name).

import "version" as version;

# Adds `keep: true|false` to each candidate package (input: [{repo, name, arch, version, ...}]).
# Per (name, arch): majors N and N-1 keep the latest patch of each minor, older majors go;
# `retain` versions and `keep-releases` lines are always kept.
def apply($cfg):
  group_by([.name, .arch])
  | map(
      map(. + {v: (.version | version::parse)})
      | (map(.v[0]) | max) as $n
      | group_by(.v[0:2])
      | map((map(.v[2]) | max) as $latest | map(. + {latest: (.v[2] == $latest)}))
      | add
      | map(. as $p | ($cfg[$p.repo] // {}) as $rc
          | . + {keep: (
              ($p.latest and $p.v[0] >= $n - 1)
              or (($rc.retain // []) | any(.package == $p.name and .version == $p.version))
              or ($p.latest and (($rc["keep-releases"] // [])
                | any(. == "\($p.v[0]).\($p.v[1])")))
            )})
      | map(del(.v, .latest)))
  | add // [];
