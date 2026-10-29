# Integration tests

`tests/integration/` tests the distributor end to end on real GitHub with bats-core: each test
makes releases on throwaway service repos, dispatches polls of a throwaway distributor, and
checks its state, issues, and published repositories. Unit tests (`tests/unit`, later) are the
quick sanity check; this is the real insurance.

The throwaway repos are overwritten completely on every run. Use repos made for this only.

## Requirements

- podman or docker. The suite runs in one transient tools container (`fedora:42`; bats, gh,
  git, gpg, rpm and deb tools are installed there); the install checks run in clean sibling
  containers through the host engine's socket. Nothing is installed on the host.
- `yq` on the host (either implementation), for the config.
- `gh`, logged in, with the `repo` scope (`gh auth refresh -s repo`). No `workflow` scope: git
  pushes go over SSH, where token scopes don't apply.
  The token reaches the container on stdin only: never a file, the container's environment, or
  a command line.
- An SSH agent (`SSH_AUTH_SOCK`) holding a key GitHub accepts: git pushes over SSH through it.
- Local checkouts of the distributor and the testbed with no uncommitted changes to tracked
  files. Their HEAD commits are what get tested.

## Repos

```bash
tests/integration/init.sh      # create the three repos
tests/integration/destroy.sh   # delete them, when done
```

`init.sh` creates `it-<random>-distributor`, `it-<random>-testbed`, and
`it-<random>-testbed-tools` (public, empty) under your account and records them in
`tests/integration/repos.yaml` (gitignored; `IT_REPOS` overrides the path). Every run reuses them
until you destroy them.

`destroy.sh` deletes exactly the repos in that file, after checking each is yours and named like
init's, and only after you type `Y` having seen their names. It also deletes the testbed's images
in your GHCR namespace, then the file. It needs the `delete_repo` scope, and `delete:packages`
for the images (`gh auth refresh -s delete_repo,delete:packages`).

Repos made by hand work too: set `repos` in the config instead. package-rules' longer-repo-name
check runs only when the second service repo's name starts with the testbed's name plus `-`.

## Configuration

Copy `tests/integration/config.example.yaml` to `tests/integration/config.yaml` (gitignored;
`IT_CONFIG` overrides the path). It holds every setting that isn't a secret: the checkouts, the
repos (when not made by init.sh), the images, the engine, the output directory, timeouts, and
`keep` (skip the end-of-run cleanup to inspect what a run left).

## Running

```bash
tests/integration/run.sh                     # every test
tests/integration/run.sh retention noop      # these tests (cases/<name>.bats)
tests/integration/run.sh --filter deny       # bats options pass through
```

Logs go to stderr; the results (TAP) go to stdout and to `<output_dir>/<run id>/report.tap`.
Tee stderr yourself to keep the log. The exit status is bats': 0 when every test passed.

Each run:

1. Once (setup_suite): checks the repos (guard, below), generates a throwaway key chain (root, a
   repo key per service repo certified by the root, an archive key), wipes the repos (releases,
   tags, issues, labels, workflow runs), sets their secrets, and force-pushes the local
   checkouts with the suite's changes: the distributor gets the default test config, empty
   state, and no cron schedule (tests dispatch every poll); the testbed pushes its images to
   your GHCR namespace.
2. Before every test: resets the baseline, so no test depends on another: no releases, tags,
   issues, or labels; the distributor back on its seed commit (default config, empty state);
   no poll running.
3. Once at the end (teardown_suite): wipes the repos and deletes their secrets, unless `keep`.

Tests wait on GitHub by checking every `poll_interval` seconds up to `timeout` per wait, never by
sleeping a fixed time. Ctrl-C stops the running test and still runs the teardowns.

## Tests

| Test | What it checks |
|---|---|
| admit-new-release | a new release is admitted and its packages published |
| noop | a poll with nothing new skips admission and commits nothing |
| retention | a new patch release prunes the previous patch's packages |
| prerelease | a GitHub prerelease is ignored (no state entry, no issue) |
| missing-sidecars | a release without signature sidecars is rejected once, with one issue |
| retag | a retagged copy of an admitted release is rejected |
| bad-signature | a release signed by an uncertified key fails the trust chain |
| deny-key | denying a repo key prunes it, opens an issue, rejects its new releases |
| deny-since | denying a key from a date prunes only what it admitted since |
| cancel | a poll cancelled mid-run commits nothing; the next one admits normally |
| prune-failing | a failing prune keeps an issue open until it recovers |
| package-rules | package name, version, and ownership rules across two repos |
| release-cap | one poll processes at most MAX_RELEASES releases (lowered to 3) |
| overlapping-polls | two polls dispatched together admit a release once |
| install-real-build | a real testbed release (GoReleaser, signing) installs with dnf and apt from the published repositories, signatures checked |

Every test but install-real-build uses crafted releases: tiny real rpm and deb packages, signed
through the run's key chain the way gpg-sign-artifacts signs, on the second service repo (no
workflows there, so tags trigger nothing). install-real-build is the one test that waits for a
real release build.

## Guard

Before changing anything, setup and teardown refuse unless every repo is public, not a fork, and
either empty or carrying the `.distributor-it` marker file the suite pushes.

## Notes

- Not covered: the scheduler (GitHub's cron is unreliable), and the release publisher check (not
  implemented yet).
- The testbed's trivy job fails in a personal account (it reads org packages), and its reuse
  check flags the marker file; releases don't depend on either.
