#!/usr/bin/env bash
# Creates the S3 suite's AWS resources and records them in the state file
# (~/.local/state/distributor-it/s3.json; IT_S3_STATE overrides), which s3/run.sh and
# s3/destroy-aws.sh read:
#
#   bucket distributor-it-<random>    objects public-read, no public listing, every object
#                                     expires after 3 days, standard storage, no versioning
#   IAM user distributor-it-<random>  may only list the bucket and read, write, and delete in
#                                     it; one access key
#
#   s3/init-aws.sh [region]               default: AWS_REGION, else us-east-1
#
# Uses your AWS CLI credentials (an admin; AWS_PROFILE picks a profile). S3 has no size quota:
# the expiry and the suite's prune keep the bucket small (a run publishes a few MB), nothing
# caps it. Refused when the state file already exists.
set -uo pipefail

# shellcheck source=../lib/log.sh
source "$(dirname "$0")/../lib/log.sh"
# shellcheck source=../lib/random.sh
source "$(dirname "$0")/../lib/random.sh"
# shellcheck source=lib/aws.sh
source "$(dirname "$0")/lib/aws.sh"

################################################################################
# The bucket policy: anyone may read objects (the distros install anonymously); listing isn't
# granted.
# Arguments:
#   Bucket.
# Outputs:
#   The policy (JSON) on stdout.
################################################################################
s3_init__bucket_policy() {
  jq -nc --arg b "$1" '{Version: "2012-10-17", Statement: [{Effect: "Allow", Principal: "*",
    Action: "s3:GetObject", Resource: "arn:aws:s3:::\($b)/*"}]}'
}

################################################################################
# The user's policy: the distributor's needs on this bucket only. s3:ListBucket makes a
# missing object read as missing, not as access denied (docs/deployment.md).
# Arguments:
#   Bucket.
# Outputs:
#   The policy (JSON) on stdout.
################################################################################
s3_init__user_policy() {
  jq -nc --arg b "$1" '{Version: "2012-10-17", Statement: [
    {Effect: "Allow", Action: "s3:ListBucket", Resource: "arn:aws:s3:::\($b)"},
    {Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      Resource: "arn:aws:s3:::\($b)/*"}]}'
}

################################################################################
# Public access: ACLs stay blocked (objects are public only through the bucket policy); the
# public policy is allowed.
# Outputs:
#   The public access block configuration on stdout.
################################################################################
s3_init__public_access() {
  printf '%s' BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,
  printf '%s\n' RestrictPublicBuckets=false
}

################################################################################
# Every object expires after 3 days; unfinished uploads are dropped after 1.
# Outputs:
#   The lifecycle configuration (JSON) on stdout.
################################################################################
s3_init__lifecycle() {
  jq -nc '{Rules: [{ID: "expire", Status: "Enabled", Filter: {}, Expiration: {Days: 3},
    AbortIncompleteMultipartUpload: {DaysAfterInitiation: 1}}]}'
}

################################################################################
# Creates the bucket.
# Arguments:
#   Bucket, region.
# Returns:
#   0, or 1 when a step failed.
################################################################################
s3_init__bucket() {
  local name=$1 region=$2 location=()
  # us-east-1 is the default location and refuses being named.
  if [[ $region != us-east-1 ]]; then
    location=(--create-bucket-configuration "LocationConstraint=$region")
  fi
  aws s3api create-bucket --bucket "$name" --region "$region" "${location[@]}" > /dev/null &&
    aws s3api put-bucket-tagging --bucket "$name" --region "$region" \
      --tagging 'TagSet=[{Key=purpose,Value=distributor-it}]' &&
    aws s3api put-public-access-block --bucket "$name" --region "$region" \
      --public-access-block-configuration "$(s3_init__public_access)" &&
    aws s3api put-bucket-policy --bucket "$name" --region "$region" \
      --policy "$(s3_init__bucket_policy "$name")" &&
    aws s3api put-bucket-lifecycle-configuration --bucket "$name" --region "$region" \
      --lifecycle-configuration "$(s3_init__lifecycle)"
}

################################################################################
# Creates the user and its access key, recorded in the state file. The secret goes from the
# AWS CLI to the file through a pipe only.
# Arguments:
#   User (and bucket).
# Returns:
#   0, or 1 when a step failed.
################################################################################
s3_init__user() {
  local name=$1
  aws iam create-user --user-name "$name" --tags Key=purpose,Value=distributor-it > /dev/null &&
    aws iam put-user-policy --user-name "$name" --policy-name bucket \
      --policy-document "$(s3_init__user_policy "$name")" &&
    aws iam create-access-key --user-name "$name" --output json |
    aws__state_set --slurpfile k /dev/stdin '$k[0].AccessKey as $a
      | if $a == null then error("no access key") else . end
      | .access_key_id = $a.AccessKeyId | .secret_access_key = $a.SecretAccessKey'
}

main() {
  local region=${1:-${AWS_REGION:-us-east-1}} file name
  file=$(aws__state_file)
  if [[ -e $file ]]; then
    log__fatal "already initialized: $file lists AWS resources; s3/destroy-aws.sh deletes them"
  fi
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log__fatal "the AWS CLI has no working credentials (aws configure, or set AWS_PROFILE)"
  fi
  name=distributor-it-$(random__hex 8)

  # Recorded first, so a failure part way still leaves destroy-aws.sh the names.
  mkdir -p "$(dirname "$file")" || log__fatal "can't create $(dirname "$file")"
  if ! (umask 077 && jq -n --arg n "$name" --arg r "$region" '{bucket: $n, user: $n,
    region: $r, url: "https://\($n).s3.\($r).amazonaws.com"}' > "$file"); then
    log__fatal "can't write $file"
  fi
  s3_init__bucket "$name" "$region" ||
    log__fatal "the bucket $name wasn't set up; s3/destroy-aws.sh deletes what was created"
  log__info "created the bucket $name ($region)"
  s3_init__user "$name" ||
    log__fatal "the user $name wasn't set up; s3/destroy-aws.sh deletes what was created"
  log__info "created the IAM user $name and its access key"
  log__info "recorded in $file; s3/run.sh uses it (new access keys can take a minute to work)"
}

main "$@"
