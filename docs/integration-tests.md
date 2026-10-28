# Integration tests

`tests/integration/run-integration-test` runs the cases in [testing-guide.md](testing-guide.md)
(step 6) end to end on real GitHub: it tags real testbed releases, crafts others, dispatches
polls, and checks the distributor's state, issues, and published repositories. Unit tests
(`tests/unit`, later) are the quick sanity check; this is the real insurance.

It runs against three throwaway repos that it overwrites completely on every run. Use personal
repos made for this and nothing else.

## Requirements

- podman or docker. Everything runs in transient containers (`fedora:42`, and `debian:13` for the
  apt check); nothing is installed on the host.
- `gh`, logged in, with the `repo` and `workflow` scopes (`gh auth refresh -s repo,workflow`). The
  token reaches each container on stdin only: never a file, the container's environment, or a
  command line.
- Three empty public repos under your personal account. Case 12's longer-repo-name check runs only
  when the second service repo's name starts with the testbed's name plus `-`:

  ```bash
  for r in it-distributor it-testbed it-testbed-tools; do gh repo create "$r" --public; done
  ```

- Clean local checkouts of the distributor and the testbed. Their HEAD commits are what get
  tested; the suite refuses uncommitted changes.
- RAM for the run directory in `/dev/shm` (a few hundred MB, mostly the dnf cache).

## Configuration

Copy `tests/integration/config.env.example` to `tests/integration/config.env` (gitignored) and
fill it in, or point `IT_CONFIG` at another file. Variables set in the environment override the
file.

| Variable | |
|---|---|
| `IT_DISTRIBUTOR_REPO`, `IT_TESTBED_REPO`, `IT_SERVICE2_REPO` | the throwaway repos (required) |
| `IT_DISTRIBUTOR_DIR`, `IT_TESTBED_DIR` | the local checkouts (required) |
| `IT_DUMMY_TOKEN_CMD` | a command printing a dummy account's token, for the release publisher check once it exists |
| `IT_OUTPUT_DIR` | where reports go (default `/tmp/distributor-it`) |
| `IT_TIMEOUT`, `IT_POLL_INTERVAL` | per-wait timeout and check interval, in seconds (3600, 20) |
| `IT_ENGINE` | `podman` or `docker` (default: podman if installed) |
| `IT_KEEP` | set to skip teardown and keep the run's releases, issues, and runs |

## Running

```bash
tests/integration/run-integration-test all      # every case, in the presentation order
tests/integration/run-integration-test 9 14     # just these
```

A single case builds whatever it needs first (e.g. published releases), so it runs alone; that
can mean waiting for testbed release builds. `all` runs the cases in the testing guide's
presentation order (section 7), so later cases reuse what earlier ones set up. Expect `all` to
take a couple of hours, mostly release builds and polls.

Each run:

1. Setup: checks the repos (guard, below), generates a throwaway key chain (root, a repo key per
   service repo certified by the root, an archive key), wipes the repos (releases, tags, issues,
   labels, workflow runs), sets their secrets, and force-pushes the local checkouts plus one
   commit with the suite's changes: the distributor gets a test config, empty state, and no
   cron schedule (the suite dispatches every poll); the testbed pushes its images to your GHCR
   namespace.
2. Cases: each in its own container, waiting on GitHub by polling (`IT_POLL_INTERVAL`) up to
   `IT_TIMEOUT` per wait, never by sleeping a fixed time. Case 11 then installs `testbed` from the
   published target with dnf and apt, signatures checked, in separate containers.
3. Teardown: wipes the repos again and deletes their secrets (skipped with `IT_KEEP`).

## Guard

Before changing anything, setup and teardown refuse unless every repo:

- isn't under OpenCHAMI, and all three share one owner;
- is public and not a fork;
- is empty, or carries the `.distributor-it` marker file a previous run pushed.

## Results

The terminal and `<IT_OUTPUT_DIR>/<run id>/log.txt` show live progress. `report.tsv` has one line
per case: `pass`, `fail` (the distributor misbehaved), `error` (GitHub or setup failed, e.g. a
timeout or a failed release build), or `skip`, with the first failed check and the distributor's
run URLs. The process exits 0 when nothing failed, 1 on a failure, 2 on an error. Case 11's
downloaded targets stay in the run's output directory for inspection.

Containers are removed when they exit, and the shared run directory in `/dev/shm` (keys, dnf
cache, intermediate results) is deleted when the run ends, even on failure.

## Notes

- Not covered: the scheduler (GitHub's cron is unreliable), and the release publisher check
  (not implemented yet; it will use `IT_DUMMY_TOKEN_CMD`).
- Case 13 lowers `MAX_RELEASES` to 3 in the throwaway distributor, so four releases test the cap.
- The testbed's trivy job fails in a personal account (it reads org packages); the release
  itself doesn't depend on it.
- Testbed images pushed to your GHCR namespace stay after teardown; delete them by hand if you
  like (`gh` needs the `delete:packages` scope for that).
- Every testbed tag goes on its own new empty commit, so GoReleaser always builds the right
  version (github-actions#59).
