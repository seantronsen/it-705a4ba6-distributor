# Distributor spec: deferred

Everything outside the prototype ([spec.md](spec.md)). Archive key management and the keyring
package are on `seantronsen/feat/keyring`. Parked work lives on branches:
`seantronsen/wip/keepalive` and `seantronsen/wip/tests`. Both predate review 1 and need
reconciling with the reworked prototype.

## Order

1. Integration tests: the next round, per the review notes (Testing), including the S3 and archive
   key cases.
2. Unit tests: rework `seantronsen/wip/tests`, after the integration round.
3. Revise the whole repo, workflows through scripts (not tests): the cleanup TODOs under Later.
4. Presentation.
5. Keepalive workflow.
6. Trigger mechanism (cron fires only a few times a day).
7. Tentative: stop paging releases once discover reaches ones already in state.
8. Maybe: adopt github-actions' `Makefile.common` (mostly for test targets; little else applies).

Deferred, possibly indefinitely: state on its own branch, apk and pacman, per-distro-version
repositories, the notifier.

## Archive key management

On `seantronsen/feat/keyring`.

- `ARCHIVE_GPG_KEY` (and passphrase, if any) is a secret on this repo. The public key is committed
  as `keys/archive.asc` and published at the same path in the target.
- Creating an archive key: generate it as its own primary key (not a subkey of the root key), and
  have the offline root key certify it, the same way the root certifies repo keys. dnf and apt
  ignore certifications, so clients are unaffected; the certification lets anyone verify that an
  archive key is OpenCHAMI's against the root key, which matters most for a key switch after a
  compromise. A subkey would make anything that trusts the root also trust the archive key's
  signatures, and rotating it would mean editing the root key. Every new archive key (yearly
  rotation, compromise) gets the same certification.
- `keys/` holds `archive.asc` (what clients import), `archive-next.asc` and
  `archive-previous.asc` during a rotation, and `revoked-<fingerprint>.asc`. The target carries
  the same files under `keys/`.
- `scripts/check-keys.sh` runs in poll's `keys` job, before discover: it fails the run within 30 days of the
  archive key's expiry and opens or updates an `Archive key expiring` issue, and fails if
  `ARCHIVE_GPG_KEY`'s public key doesn't match `keys/archive.asc` (e.g. a half-finished switch).
  Both checks are skipped for a throwaway key. It also opens or updates an `Archive key switch
  due` issue once `keys/archive-next.asc` has been committed for 30 days (the grace period is
  over; rotation step 3 is due), without failing the run; the switch commit closes it.
- Packages are signed with whatever archive key was current when they were published, so a key
  change has to reach every package still published. Retention bounds that set. rpms record
  which archive key signed them (`signed_with` in state), so `rekey` can resume.
- Any workflow that writes state (poll's and prune's record, keyring, rekey, keepalive) shares
  the `poll` concurrency group and applies its changes as a delta onto the latest committed
  state.

### Rotation (planned, yearly, manual for now)

Start at least 60 days before the current key expires: 30 days of grace for clients, before
`check-keys` starts failing runs 30 days out.

1. Generate the next key, kept offline for now, have the root key certify it (see above), and
   commit its public key as `keys/archive-next.asc`.
2. The `keyring` workflow (triggered by the `keys/` change) releases a keyring carrying both keys,
   signed with the current key, so clients pick up the next key through a normal upgrade. Leave a
   grace period (30 days) for upgrades.
3. Switch: a maintainer sets `ARCHIVE_GPG_KEY` to the next key (workflows can't edit secrets) and
   commits the key files moved one step: `archive-next.asc` becomes `archive.asc`, the old
   `archive.asc` becomes `archive-previous.asc`. From then on every publish signs with the new
   key, and the keyring still carries the old one.
4. Run the `rekey` workflow: it re-signs every published rpm whose `signed_with` isn't the current
   key, and re-signs the repository metadata. It updates `signed_with` in state as it goes, so a
   failed `rekey` can simply be run again.
5. Once `rekey` has finished, delete `keys/archive-previous.asc`; the keyring rebuilds without
   the old key.

Re-signing works one package at a time (download, `rpmsign --delsign` then `--addsign`, upload),
then updates the rpm metadata for the re-signed batch through the same idempotent merge as
publishing. debs carry no signature, so apt only needs `Release` re-signed. `rekey` gets a longer
timeout than poll's 30 minutes.

### Archive key compromise

Same switch and `rekey` run, immediately, with a freshly generated key and no grace period. Also:

- A maintainer revokes the old key by hand and commits its revoked public key as
  `keys/revoked-<fingerprint>.asc`; the next keyring ships it. No revocation certificates are
  generated or kept.
- Clients that only trust the compromised key can't trust a keyring update signed by the new key,
  so they re-import the new key over HTTPS (README procedure), and can check its root
  certification first.
- Open an issue and announce it.

## Keyring package

`openchami-keyring` (rpm and deb), built by `scripts/keyring.sh` with nfpm from
`keyring/nfpm.yaml`, at the latest keyring version in state with the patch bumped (1.0.0 first),
so retention keeps only the latest keyring. It installs every public key in
`keys/`. It's published through the same publish step and default retention (no `repos.yaml`
entry), exempt from admission, and recorded in state under
`openchami-keyring@<version>`. Built by the `keyring` workflow (manual, and on changes to
`keys/`).

The README is the first stop for client setup: installing the keyring, the dnf `.repo` file, and
the apt `sources` entry, plus the compromise procedure. openchami.org's docs will carry the same.

## Keepalive

Parked on `seantronsen/wip/keepalive`. GitHub disables scheduled workflows in public repos after
60 days without activity. State commits keep it active while releases flow; a monthly
`keepalive` workflow commits a timestamp to `state/keepalive` when nothing else has been
committed for 30 days. Keep the 30-day threshold a single variable so the integration suite can
override it (e.g. with sed on the pushed copy) and test keepalive in minutes.

## Testing

Two layers: the unit tests are a quick local sanity check of the scripts; the integration suite
on real GitHub is the real insurance. Common to both:

- Each generates its own throwaway key chain (root, repo, release, and archive keys); no test
  touches a real key.
- Client checks: install from the published repositories with `dnf` (Rocky/Fedora image,
  `gpgcheck` and `repo_gpgcheck` on) and `apt` (Debian image, `signed-by` the archive key).

### Unit tests

Parked on `seantronsen/wip/tests`.

- bats-core tests for the scripts, run in a test image (the tools plus bats and GoReleaser):
  every rejection path, the name and version rules, ignored formats and architectures,
  already-admitted versions, retention (including `retain` and `keep-releases`), incremental
  metadata updates, and `deny` pruning.
- Fixtures: generated releases (GoReleaser-built packages signed through the throwaway key chain)
  for each rejection and retention case, plus real testbed releases. Discover reads releases
  from a fixtures directory instead of the GitHub API.
- The branch still relies on the old phased admit, the vendored `verify-chain.sh`, and the
  local-run tooling (`run-local.sh`, `in-tools.sh`); rework it against the new admit, which
  fetches the trust-chain script.

### Integration suite

[integration-tests.md](integration-tests.md) covers usage, the tests, and the code conventions.
Remaining:

- TODO: S3 in the suite, as cases: a test bucket in settings, its credentials (scoped to that
  bucket) set as the throwaway distributor's secrets, `target.s3` in the default config, and the
  distro tests installing from the bucket's HTTPS URL instead of the local versitygw. Cover
  prune's deletions and orphan reconcile against the bucket too. For client checks: bare
  `debian:13` lacks `ca-certificates`, so apt can't fetch over HTTPS until it's installed.
- TODO: archive key cases: the `keyring` workflow and installing the keyring with dnf and apt,
  `rekey.yml` after a key switch, and both `check-keys` issues (expiring, switch due). All
  implemented; tested locally only.
- Flake resilience: GitHub-side failures (e.g. actions/download-artifact giving up after its
  retries) fail a test though the distributor recovers on the next poll. Options: retry flaky
  steps in the distributor; the suite re-dispatches one poll when a poll fails in a
  known-transient step (a narrow list, so real failures still fail).
- Speed: fewer polls by batching the one-poll rejection tests (Sean: isolation is worth more for
  now; explore parallelism later, within the serial-runs limit); a lower `poll_interval`;
  per-job timings from a kept run. real-build is dominated by the testbed's emulated aarch64
  validate job.
- Small open items: `run.sh --help` via sed; config duplication across the deny tests; stage.sh
  couples distro to ci's setup (leave for now); `die` -> `fatal` in `scripts/lib.sh`.
- TODO at real deployment: an org repo, `OpenCHAMI/distributor-sandbox`, for running the suite
  so it no longer depends on personal repos and the real distributor ships nothing test-only
  (sandbox config, test state, test secrets). It will likely work closely with the
  github-actions testbed (testbed releases as its inputs, shared test tags and keys).
- TODO: a PR template for this repo stating that a PR changing code or config (scripts,
  workflows, config, tests) must pass every integration test, with the run's report attached,
  to be eligible for review. Docs-only PRs are exempt.

#### Review notes (2026-11-03): for the redesign after the planned features

Sean's review of v4 (CI 15/15, distro 4/4): good enough to ship; nothing critical. Everything
below waits for one redesign round, after every planned feature lands, that revises the
integration and unit testing architectures together and folds in the new tests.

Design rule for the libs: functions are written for reuse. No static assumptions about specific
repos or roles in a function body; take what's needed as arguments. Where an assumption stays
for simplicity, the file or function doc comment says so and what would change it.

Cases:

- Case file doc comments (the one-line description at the top) are too thin; workshop them.
  The lib file comments are fine.
- admit-new-release: nothing checks that the published packages match what was uploaded
  (content, not just state). Potential improvement; debate whether it's needed.
- bad-signature: the name is imprecise. `checksums.txt.asc` is a valid signature by a signing
  key the repo key never certified, so it's a broken chain (uncertified signing key), not a
  bad signature. Rename (e.g. `uncertified-key`).
- package-rules: hard to read. Split into stages (releases, poll, checks) with a sub-test per
  expected check, or at least restructure for readability; roughly five stages, so a
  discussion topic.
- retention: covers patch supersession only. Cover the whole policy (N/N-1 majors keep the
  latest patch per minor, N-2 and older pruned, `retain`, `keep-releases`), each aspect with
  its own setup, since e.g. a new major prunes the older lines.
- cancel: gh API paging is messy; revisit only if it's reconsidered after the first release.
- Formats: rpm and deb are hardcoded through the suite (as in the distributor). apk and pacman
  (Later) would need large redesigns of both. Out of scope; noted.

Libs:

- Overall: room for simplification, deduplication, and abstraction that favors readability;
  some small lib redesigns.
- `crafted.sh`: the name is poor for what builds release files; discuss. `crafted__sign`
  derives the key role from the repo name (testbed or service2); take the role (or key) as an
  argument instead, and update the call chains.
- `poll.sh`: `poll__run` hardwires the distributor repo. Fine while runs are serial, but state
  that in the file comment, with what would change for parallelism.
- `distributor.sh`: `distributor__push_config` may mix concerns by also waiting for the push's
  poll; discuss.
- `wait.sh`: `wait__check`'s 10 s retry sleep and its 3 tries are hardcoded; make them settings
  (`config.defaults.yaml`).
- TODO, reconsider: a JSON Schema for the test config (`config.defaults.yaml` and user
  overrides), as `config/repos.schema.json` does for the distributor. Not yet: the settings are
  still fluid, `lib/config.sh` already checks every setting it reads, and it would add Python and
  `check-jsonschema` to the host requirements (today only `yq` and `jq`).

New, unnecessary but wanted:

- A replication mode: a `repos` option in `config.defaults.yaml` that mirrors the real
  distributor locally, polling every eligible OpenCHAMI repo (per the real `repos.yaml`), so a
  test can watch releases get pulled in and pruned from start to finish, then test the final
  state locally (distro side: installs, package interop, requirements). The repo may be too big
  for CI artifacts, which would need a test S3 endpoint. Pairs with the existing `keep`
  settings.
- Distributor idea: a scheduled job that checks published packages (standardization,
  vulnerabilities).

Repo-wide: adopt github-actions' `Makefile.common` (simpler test runs, REUSE headers, the
standard tooling); probably after the keyring.

## Hosting

- The production bucket: provider, domain, account owner (deployment.md).
- Exact polling interval.

## Release publisher check

Remaining (the check itself is spec.md, Admit step 2):

- The integration suite: add `publishers` to its default config; push a no-op tag workflow to
  the second service repo (crafted releases have no runs, so every one is rejected); have
  `crafted__release` wait for the tag's push run before polling. Then cases for an allowed
  publisher, one not listed, and a lead limited to another repo. Batched with the other test
  work.
- Make `validate-config` a required status check on `main` (repo setting).

## Presentation

A LaTeX (beamer) slide deck with diagrams for the team, kept simple: what the design is, how a
release flows through it, caveats (a retry is a new patch release; rejected releases are never
reprocessed; the cron schedule is unreliable), security posture and open security questions, and
the requirements on others: only core maintainers can change this repo at all (no PRs from
anyone else), and `v*` tag pushes on every service repo are limited the same way (or enforced by
the publisher check above). Then the testing-guide's presentation run as the demo.

## Later

- TODO, consider: drop the local directory target once S3 is proven, which simplifies every
  `target_*` function. Blocked until the suite has an internet-reachable test bucket: its CI and
  distro tests read the local target's artifacts.
- TODO: read config in `scripts/` the way the integration suite does (`config__get` /
  `settings__get`): one getter for every setting that needn't be an environment variable, no
  defaults in code, a missing key is an error. Replaces the ad hoc `yq`/`jq` reads and the
  exported `TARGET_S3_*` variables. A bigger edit; do it once the features are in.
- TODO: trim the doc comments in `scripts/` (many are too verbose), during the cleanup.
- TODO: use the `gh` CLI for every GitHub API call in `scripts/lib.sh` (curl wrapper, page loops,
  asset downloads, issue helpers; about 30 lines). Paginate with `--paginate` plus per-page
  `--jq` and `jq -s`, not `--slurp` (gh 2.48+; older gh, e.g. Debian's, lacks it).
- TODO: build the suite's crafted packages (`ci/lib/crafted.sh`) with nfpm, as real releases do
  through GoReleaser (about 30 lines; pinned nfpm binary in the tools container).
- apk and pacman. Both can update their indexes without old packages (tested): pacman natively
  with `repo-add` / `repo-remove` (`--sign`); apk by merging `APKINDEX` stanzas by hand
  (`apk index --index` drops entries for absent packages), re-tarring, and signing with
  `abuild-sign`.
- Per-distro-version repositories (per-EL rpms, per-Debian-release suites).
- Repo name.
- State on its own unprotected branch, so the poller bot needs no bypass on the protected default
  branch (a bypass can't be scoped to `state/state.json`). Unverified: whether commits to that
  branch count as activity for GitHub's 60-day scheduled-workflow rule.
- Not planned: ignoring releases published before a repo was added to `repos.yaml`. Today's
  releases of smd, bss, magellan, ochami, opaal, tokensmith, and release carry unsigned packages
  with no sidecars; the first polls reject each one (256 per poll, oldest first) and open an
  issue per release, until state covers them all. That's intended.
- TODO: key `repos` in `config/repos.yaml` by repo name, like `publishers` (duplicates become a
  parse error; `by_name` and the `select(.name == $repo)` lookups go away). Same pass: drop the
  `tostring` and `ascii_upcase` the schema makes redundant (require uppercase fingerprints), and
  allow uppercase in `allow` names (rpm permits them).
- TODO: run `validate-config.yml` on `ubuntu-latest`, like every poll job.
- TODO: refactor `scripts/prune.sh`: the decisions, the orphan reconcile, the metadata rewrite,
  and the deletes are all inline; split them into small functions.
- TODO: refactor `scripts/admit.sh`. It's the hardest script to read: long inline jq programs
  (the name, ownership, and duplicate rules), mixed shell and jq state, and checks of very
  different sizes in one file. Move the jq into `lib.jq` (or its own `.jq` file) and split the
  checks into small functions of similar shape.
- `releases_list` gets more expensive as releases accumulate (every poll lists every release);
  see Order, item 10.

## Possibly never

- A notifier for newly published packages: email first, Slack later (Slack needs permission to
  set up). GitHub issues already notify watchers, and delivery is hard to test.
