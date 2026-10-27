# Distributor spec: deferred

Everything outside the prototype ([spec.md](spec.md)). Parked work lives on branches:
`seantronsen/wip/rekey-keyring` (archive key management and the keyring package),
`seantronsen/wip/keepalive`, and `seantronsen/wip/tests`. All three predate review 1 and need
reconciling with the reworked prototype.

## Archive key management

Parked on `seantronsen/wip/rekey-keyring`.

- `ARCHIVE_GPG_KEY` (and passphrase, if any) is a secret on this repo. The public key is committed
  as `keys/archive.asc` and published at the same path in the target. The throwaway-key fallback
  is only allowed with the local target: with S3 or a domain configured and no key, the run fails.
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
- `scripts/check-keys.sh` runs at the start of every poll: it fails the run within 30 days of the
  archive key's expiry and opens or updates an `Archive key expiring` issue, and fails if
  `ARCHIVE_GPG_KEY`'s public key doesn't match `keys/archive.asc` (e.g. a half-finished switch).
  Both checks are skipped for a throwaway key.
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

`openchami-archive-keyring` (rpm and deb), built from `keyring/.goreleaser.yaml`: GoReleaser with
`builds: skip` and an nfpm `meta` package of the key files, in snapshot mode with
`snapshot.version_template` set to a plain `major.minor.patch` from the workflow, the patch bumped
on every build, so retention keeps only the latest keyring. It installs every public key in
`keys/`. It's published through the same publish step and default retention (no `repos.yaml`
entry), exempt from admission, and recorded in state under
`openchami-archive-keyring@<version>`. Built by the `keyring` workflow (manual, and on changes to
`keys/`).

The README is the first stop for client setup: installing the keyring, the dnf `.repo` file, and
the apt `sources` entry, plus the compromise procedure. openchami.org's docs will carry the same.

## Keepalive

Parked on `seantronsen/wip/keepalive`. GitHub disables scheduled workflows in public repos after
60 days without activity. State commits keep it active while releases flow; a monthly
`keepalive` workflow commits a timestamp to `state/keepalive` when nothing else has been
committed for 30 days.

## Testing

Parked on `seantronsen/wip/tests`.

- bats-core tests for the scripts, run in a test image (the tools plus bats and GoReleaser):
  every rejection path, the name and version rules, ignored formats and architectures,
  already-admitted versions, retention (including `retain` and `keep-releases`), incremental
  metadata updates, and `deny` pruning.
- Fixtures: generated releases (GoReleaser-built packages signed through a throwaway key chain)
  for each rejection and retention case, plus real testbed releases. In tests, discover reads
  releases from a fixtures directory instead of the GitHub API. End-to-end runs need a stable
  (non-prerelease) testbed tag.
- Client checks: install from the published directory with `dnf` (Rocky/Fedora image, `gpgcheck`
  and `repo_gpgcheck` on) and `apt` (Debian image, `signed-by` the archive key).
- The tests branch still relies on the old phased admit, the vendored `verify-chain.sh`, and the
  local-run tooling (`run-local.sh`, `in-tools.sh`); rework it against the new admit, which
  fetches the trust-chain script.
- TODO at real deployment: an org fork, `OpenCHAMI/distributor-sandbox`, for end-to-end testing,
  so it no longer runs in someone's personal repo and the real distributor ships nothing
  test-only (sandbox config, test state, test secrets). It polls the github-actions testbed and
  will likely work closely with it (testbed releases as its inputs, shared test tags and keys).

## Hosting

- The S3 / domain publish target: implement the `target_*` functions in `lib.sh` (e.g. with
  `aws s3`). Blocked on the hosting decision (provider, domain, account owner).
- With the S3 target, add `target_list`, and have prune reconcile: list package paths on the
  target (`rpm/packages/`, `deb/pool/`; never `keys/` or metadata), and remove any file state
  doesn't list as `published`, metadata first. This covers files left behind by the escape hatch
  (deleted state can't rediscover deleted releases) and by runs that died mid-write. It replaces
  spec.md's "nothing has to list the publish target": every backend we can write to can be listed.
  Safe because prune runs in the `poll` concurrency group, never alongside publish.
- Exact polling interval.

## Later

- apk and pacman. Both can update their indexes without old packages (tested): pacman natively
  with `repo-add` / `repo-remove` (`--sign`); apk by merging `APKINDEX` stanzas by hand
  (`apk index --index` drops entries for absent packages), re-tarring, and signing with
  `abuild-sign`.
- Per-distro-version repositories (per-EL rpms, per-Debian-release suites).
- A notifier for newly published packages: email first, Slack later (Slack needs permission to
  set up).
- Repo name.
- State on its own unprotected branch, so the poller bot needs no bypass on the protected default
  branch (a bypass can't be scoped to `state/state.json`). Unverified: whether commits to that
  branch count as activity for GitHub's 60-day scheduled-workflow rule.
- Ignore releases published before a repo was added to `repos.yaml`. Today's releases of smd,
  bss, magellan, ochami, opaal, tokensmith, and release carry unsigned packages with no sidecars,
  so the first poll would reject each one and open an issue per release.
- `releases_list` gets more expensive as releases accumulate (every poll lists every release).
