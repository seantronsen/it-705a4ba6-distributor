# distributor (working name)

Prototype of the central repo from OpenCHAMI/github-actions#43: it polls OpenCHAMI service repos
for signed releases, verifies them, and publishes their rpm and deb packages to dnf and apt
repositories signed with the OpenCHAMI archive key.

## Layout

- `scripts/`: `discover.sh`, `admit.sh`, `publish.sh`, `prune.sh`, `record.sh`; shared `lib.sh`,
  `lib-repo.sh`, `lib.jq`.
- `.github/workflows/`: `poll.yml` resolves the commit to read, then calls one reusable workflow
  per stage (`_discover.yml`, `_admit.yml`, `_publish.yml`, `_record.yml`, `_prune.yml`). Jobs
  run on `ubuntu-latest`; publish and prune install the few tools it lacks.
- `config/repos.yaml`: who may publish, and the service repos to poll with their `allow`, `deny`,
  `retain`, and `keep-releases`; documented in its comments. `config/repos.schema.json` validates
  it, with the version of `check-jsonschema` pinned in `config/requirements.txt`.
- `state/state.json`: every release and package processed, and what happened to it.

Parked on branches: the keepalive workflow on `seantronsen/wip/keepalive` and the tests on
`seantronsen/wip/tests`.

## Running

`poll` runs on a schedule (every 10 minutes, though GitHub currently fires it only a few times a
day), on pushes that change `config/repos.yaml`, and on `workflow_dispatch`. It needs the
`MASTER_PUBLIC_ASC` and `MASTER_FPR` secrets (root public key and fingerprint).
Publishing goes to the bucket in `config/repos.yaml`'s `target.s3`, with the
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` and `ARCHIVE_GPG_KEY` (and `ARCHIVE_GPG_PASSPHRASE`)
secrets; bucket setup is in [docs/deployment.md](docs/deployment.md). Without `target`, each job
publishes to a transient directory, uploaded as a `target-<publish|prune>-<format>` artifact, and
an unset `ARCHIVE_GPG_KEY` means a throwaway key, so the result is for inspection only.
