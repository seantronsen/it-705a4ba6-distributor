# Deployment

How the publish target is expected to be set up. The distributor only pushes to an S3 bucket;
everything here is set up outside it.

## Bucket

- One S3 (or S3-compatible) bucket holding the target layout (spec.md, Target layout).
- Public read for objects; no public listing.
- The distributor uploads with per-object `Cache-Control` (S3 has no bucket-wide default):
  packages `public,max-age=31536000,immutable`, metadata and keys `public,max-age=<n>,
  must-revalidate` with `<n>` from `target.s3.metadata-max-age`.

## CDN (e.g. CloudFront)

- Likely needed for HTTPS on a custom domain (S3 website endpoints don't serve HTTPS there).
- Must honor the origin's `Cache-Control`, or cache metadata (`repodata/`, `dists/`, `keys/`)
  for at most `metadata-max-age` and packages (`rpm/packages/`, `deb/pool/`) indefinitely.
- No invalidation is needed: metadata expires within `metadata-max-age`. Alex's
  publish-rpm-repository PR (github-actions#16) invalidated metadata after each publish,
  presumably to make it visible immediately behind CloudFront at `rpm.openchami.org`.

## Domains

TBD (group decision). Not configured anywhere: the workflows only push to the bucket, and
repository metadata uses relative paths. Only client setup (dnf `.repo`, apt sources, the archive
key URL) needs them, so add them only when those docs or a `.repo` file in the keyring do.

## Settings

- `target.s3` in `config/repos.yaml`: bucket, region, and an endpoint URL when it isn't AWS.
- Secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (publish and prune only), for a
  principal with `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` on the
  bucket. `s3:ListBucket` matters: without it a missing file reads as access denied, and publish
  fails instead of starting the metadata fresh.
- `ARCHIVE_GPG_KEY` is required once `target.s3` is set (no throwaway key on a real target).
