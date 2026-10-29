# Integration suite rewrite: spec

Status: implemented 2026-10-28, not yet run on GitHub (run.sh, init.sh, destroy.sh untested
remotely). Supersedes the revision list in REPORT-2026-10-28.md.

## Implementation notes (decisions taken, deviations)

- OPEN items, as implemented:
  - Install containers: sibling containers through the host engine's socket. run.sh starts a
    private `podman system service` on a socket in the run directory (docker: its own socket);
    the tools container uses podman-remote or docker-cli. The shared run directory is mounted
    at the same path in the tools container, so sibling mounts resolve. Verified locally.
  - Failing in tests: bats' default (a failing command fails the test). Checks retry 3 times
    10 s apart (wait__check) before failing.
  - Config file: config.yaml, with config.example.yaml committed. init.sh writes repos.yaml.
  - Ctrl-C: verified locally. It stops the running test at once, then the test's teardown and
    teardown_suite run. Needed: run-in-container.sh runs bats with SIGINT's default handling
    restored and forwards the signal to its process group; run.sh and tee wait instead of quitting.
- Deviation: keys, secrets, and the force-push of the checkouts happen once per run in
  setup_suite, not in init.sh. The code under test changes between runs and the keys are
  throwaway, so they can't be made once at init. init/destroy only create and delete repos.
- Deviation: the log helpers follow the module__function rule too: log__info, log__error
  (logs, returns 1), log__die (logs, exits; scripts only).
- Dropped: the dummy-token setting (the publisher check will be buddy style or an App), and
  the docker chown (run.sh's cleanup already removes root-owned leftovers with a container).
- Size: ~1,240 code lines (not counting comments and blank lines), not the ~800 estimated. The
  difference is the conventions (include guards and source lines in every file, explicit
  `|| return 1` handling without set -e), config files written out as YAML heredocs in the tests,
  rpm crafting, the engine socket and interrupt handling, and the new admit-new-release test.

## 1. Architecture

- Framework: bats-core. It replaces the homemade runner (result codes, check/fail/skip helpers,
  report.tsv, the case loop, result/message/request files). Tests run serially (never `--jobs`;
  they share the repos).
- Boundary: the harness is case-agnostic. It starts the environment, runs bats, reports. It
  holds no case numbers, package names, or per-case steps. Each test file owns its whole flow
  and uses only generic helpers from lib/.
- Lifecycle, two levels only:
  - init / destroy (suite level, explicit, rare): create and delete the random-named repo set.
    Nothing else is shared across tests.
  - setup / teardown (per test): every test starts from a clean baseline and cleans up after
    itself. No test relies on state another test left (today `all` reuses releases across
    cases: removed). Baseline = empty distributor state, default config, no releases/tags/
    issues/labels on the service repos, no poll running.
  - Baseline cost: a config change triggers a poll (poll.yml runs on config pushes), so setup
    rewrites config only when it differs from the default, and resets state otherwise.
- Clean install containers (dnf on Fedora, apt on Debian) without nesting. OPEN; recommended:
  sibling containers through the host engine's socket (podman.sock or docker.sock mounted into
  the tools container, used by a generic `container__run <image> ...` helper). Alternative:
  bats on the host, which needs gh, git, gpg, jq, yq, rpmbuild, dpkg there.
- Error handling: no `set -e` in the launcher or lib files; functions return non-zero with a
  logged message, so several problems can be reported in one run. Inside a bats test a failing
  command fails the test (bats' own semantics). OPEN: whether that's acceptable for tests, or
  checks should collect failures and fail once at the end.
- Friendlier error presentation (where it failed and why, not a bare `|| return 1`): later.

## 2. Speed (one real build, crafted releases elsewhere)

Last run: ~68 min. Release builds 26 min (6 builds), polls 25 min (23), poll start 6 min, rest
11 min. Target ~40 min.

- One test does the full real pipeline: tag on the testbed, GoReleaser, signing, admit,
  publish, dnf and apt install from the distributor's published repositories.
- Every other test uses crafted releases on the second service repo (no workflows there, so
  `v*` tags trigger nothing). Crafted packages are tiny but real: debs (exist) and noarch rpms
  (add, via rpmbuild), since admit reads name/version/arch from the files.
- Deny tests deny the second repo's key.
- Retention and prerelease work from package versions and `gh release create --prerelease`.
- Risk: the cancel test needs admit or publish to still be running; tiny packages shorten that
  window. Pad that release's package if it gets flaky.
- Poll interval 20 s -> 10 s.
- Parked: batching several tests into one poll (complexity not worth it now).

## 3. Tests

- Named by behavior, no numbers in file names (e.g. admit-new-release.bats, retention.bats,
  missing-sidecars.bats). Isolation makes order irrelevant, so no manifest is needed; bats runs
  files in the order given, or sorted when given the directory.
- Command line: all tests, one test, or any subset by name; `--filter` for test-name regexes.
- Add an explicit good-path test, admit-new-release: a new release not in state gets admitted,
  published, and recorded. Today that's only implied inside other cases.
- Same coverage as cases 01-14 otherwise.
- Publisher check (when it exists): buddy style (a second person pushes the tag with their own
  credentials) or a GitHub App; never a second free account, never a shared token.

## 4. Launcher

- Named run.sh. Every shell file has a .sh or .bash suffix (init.sh, destroy.sh, lib/*.sh);
  tests are .bats.
- prepare_environment: config, engine, and tokens in one function.
- One engine wrapper, since every container shares the same run arguments:
  `engine_run() { "$ENGINE" run --rm --security-opt label=disable "$@"; }`.
- Scripts run inside containers are heredocs (`bash -s <<'EOF'`), not quoted `bash -c "..."`
  strings with escaping.
- Streams: logging to stderr, reporting (results table) to stdout. Only the report is written
  to a file; users `tee` the rest. With bats: results to stdout (plus a JUnit report file);
  live log lines from tests go to a descriptor the launcher points at stderr (e.g. run bats
  with `4>&2`, log helper writes to fd 4). Verify bats leaves fd 4 open to tests.
- Interrupt handling: today the EXIT trap only deletes the local run directory; remote state is
  cleaned only by teardown, which doesn't run on Ctrl-C or a crash. Next: bats runs a test's
  teardown on failure (verify on SIGINT), and every setup resets the baseline, so leftovers
  from an interrupted run can't affect the next one.

## 5. Configuration

- A YAML config file for every non-secret setting: repos (unless init's file provides them),
  checkouts, images (tools, Debian), engine, output dir, timeout, poll interval, keep flag,
  dummy-token command. Name OPEN (config.yaml with a committed config.example.yaml, or
  test.yml). Secrets never go in it.
- Read on the host with yq, which becomes a host dependency checked simply
  (`command -v yq || die`). Use only syntax both yq implementations accept: `yq -r '.a.b'
  file`, `//` for defaults; nothing mikefarah-only (eval-all, load, -i) or jq-only.
- init writes the repo names to its own gitignored file; destroy reads the same file.

## 6. Git and GitHub access

- git over SSH, required: push URLs are git@github.com:<owner>/<repo>.git. The host's SSH agent
  socket is mounted into the container (SSH_AUTH_SOCK), so no key touches disk; github.com's
  host key is pinned (known_hosts) rather than accepted blindly.
- gh still authenticates with the token on stdin (the API has no SSH path).
- Guard: drop the OpenCHAMI-owner refusal (the suite is for personal repos by definition). Keep
  the rest (public, not a fork, empty or marked).

## 7. init.sh and destroy.sh

- Shared helpers: log, die, and similar routines live once in a lib file every script sources
  (run.sh, init.sh, destroy.sh, and the container-side libs). No script redefines them.
- No OpenCHAMI checks anywhere (init's and destroy's are unnecessary, and init's tested the
  login, which can never be an org).
- init: 8 random hex characters in the base name (it-<8 hex>-...). If a name is taken, pick a
  new base and retry a few times before failing; a collision is practically impossible, two in
  a row more so.
- destroy: no --yes flag. Always show the three repo names, then read a line and continue only
  on exactly "Y"; anything else exits without deleting. The GHCR images are deleted without a
  separate confirmation.

## 8. Code conventions (lib files)

- Each lib file starts with a brief statement of its purpose. If it can't be brief, the file
  mixes concerns and gets split.
- Every function has a Google-style doc comment:
  ```
  #######################################
  # Waits until a repo has no queued or running workflow runs.
  # Arguments:
  #   owner/repo
  # Outputs:
  #   Progress on stderr.
  # Returns:
  #   0 when idle, 2 on timeout.
  #######################################
  ```
- Function names: module__function, double underscore, since names already use `_` between
  words (repos__wipe, github__dispatch_poll, keys__create). The module is the file name.
- Each file sources its own dependencies, with an include guard:
  ```
  [[ -n ${_IT_REPOS_SH:-} ]] && return 0
  _IT_REPOS_SH=1
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
  ```
- .shellcheckrc at the suite root: `source-path=SCRIPTDIR`, `external-sources=true`. Disable
  codes must be the right ones (the cleanup trap's is SC2329, not SC2317).
- Dependencies flow one way; nothing calls upward or cyclically.
- No shared mutable globals across files: only functions and readonly constants cross file
  boundaries. Repo names come from accessor functions (distributor_repo, testbed_repo,
  service2_repo) instead of D/T/S; same for RUN, OUT, WORK, CASE, MARKER. Values come back on
  stdout, never through a global (new_dispatch's NEW_RUN goes).
- Simplify across the board: functions that read as more complicated than needed get
  abstracted, simplified, or both. (Pagination helpers: dropped for now; wipe's streaming loops
  are fine.)

## 9. Answers to review questions

- runs_idle: yes, it treats any run whose status isn't `completed` (queued, in_progress,
  waiting, pending, requested) as active.
- worst: the launcher's exit code, the worst result seen (0 pass, 1 fail, 2 error); setup
  failing counts as error. Gone with bats (any failing test exits non-zero).
- client_checks: it isn't a downloader; it ran the dnf and apt install checks against case 11's
  downloaded repositories. The split design is the architecture failure in section 1.

## 10. Split: ci/ and distro/ (decided 2026-10-29, not implemented)

Why: the install checks ran in sibling containers through the host engine's socket, so the
ci tools container could start containers. S3 and the keyring package will need more
distro-level testing, so it gets its own place with the risk contained there.

Layout:

```
tests/integration/
  lib/      shared: log.sh, config.sh, engine.sh
  ci/       the CI integration tests (today's suite)
  distro/   distro-level tests of the published repositories
```

ci/:

- No engine socket, ever. One socket-less tools container per run; no podman-remote or
  docker-cli; lib/install.sh gone.
- One more bind mount: <output_dir>/<run id>/artifacts on the host. A test that produces
  something for distro/ writes it to artifacts/<test name>/.
- install-real-build becomes real-build: real release, admitted, 6 packages published, then
  the published targets copied to artifacts/real-build/{rpm,deb} (repo plus keys/archive.asc).

distro/:

- bats, phased per file: setup_file is stage 1 (runs the ci stage, e.g. ci real-build, to
  produce the artifacts, and sets up the source); each @test is one target (fedora:42 with dnf,
  debian:13 with apt) installing natively from the source; teardown_file removes what
  setup_file made. bats has no parametrized tests: one short @test per target.
- Sources:
  1. the artifact files directly (file://, mounted read-only);
  2. a temporary local versitygw (posix backend on a temp dir, public-read bucket, deleted in
     teardown_file): the artifacts are copied into <tmpdir>/<bucket>/ and the targets fetch
     over HTTP on a shared podman network, the same URL shape as real S3. Public reads on
     versitygw are confirmed by Sean.
  The distributor's own S3 upload can't reach a local versitygw from GitHub Actions; that
  test waits for a reachable test bucket.
- The engine socket is allowed here only, and only for now: it limits the blast surface to
  the distro tests and buys time to think about alternatives. distro requires podman
  (rootless; the socket is the user's own service) and refuses docker (root-equivalent).
- The key comes from the source (keys/archive.asc) until the keyring package exists; then the
  test installs the keyring package first, the way users will.
- Later: quadlet start under systemd (rootless --systemd=always) before considering a VM.

Docs (docs/integration-tests.md):

- distro: a prominent warning: a container starts containers as the user through their
  rootless podman socket, what that implies, and to review the distro test code before
  running it.
- ci: single socket-less container; safe to run without that level of scrutiny.

## Next round

- The split above (section 10).
- debian:13 for the ci tools container (Debian by default unless there's a really good reason).
- --init on engine__run, so PID 1 in a container handles Ctrl-C (the tools container ignored it
  during the install, before its trap was set).
- Doc-comment banners: 80 # characters (162 lines are 39 now).
- Last step of the revision: drop unused sources (lib/engine.sh sources log.sh for nothing).
- run.sh --help: open (Sean isn't sure about printing the header via sed; at least to stdout).
- Rename log__die to log__fatal (systems convention: fatal = log, then exit). Same for the
  distributor's own scripts: scripts/lib.sh defines die() and the workflow scripts call it; rename
  it to the matching fatal form there too (not done yet; it touches the shipped scripts).
