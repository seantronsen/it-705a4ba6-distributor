#!/usr/bin/env bash
# Deletes the AWS resources s3/init-aws.sh recorded in the state file, after you confirm their
# names: the bucket with every object in it, and the IAM user with its policy and access keys;
# then deletes the state file. Uses your AWS CLI credentials (an admin; AWS_PROFILE picks one).
set -uo pipefail

# shellcheck source=../lib/log.sh
source "$(dirname "$0")/../lib/log.sh"
# shellcheck source=lib/aws.sh
source "$(dirname "$0")/lib/aws.sh"

################################################################################
# Deletes the bucket and every object in it (no versioning, so no old versions remain).
# Arguments:
#   Bucket, region.
# Returns:
#   0 when it's gone or never existed, 1 otherwise.
################################################################################
s3_destroy__bucket() {
  if ! aws s3api head-bucket --bucket "$1" --region "$2" > /dev/null 2>&1; then
    log__info "the bucket $1 doesn't exist; skipping it"
    return 0
  fi
  aws s3 rm "s3://$1" --recursive --region "$2" --quiet &&
    aws s3api delete-bucket --bucket "$1" --region "$2" &&
    log__info "deleted the bucket $1"
}

################################################################################
# Deletes the user, its access keys, and its policy.
# Arguments:
#   User.
# Returns:
#   0 when it's gone or never existed, 1 otherwise.
################################################################################
s3_destroy__user() {
  local key keys
  if ! aws iam get-user --user-name "$1" > /dev/null 2>&1; then
    log__info "the IAM user $1 doesn't exist; skipping it"
    return 0
  fi
  keys=$(aws iam list-access-keys --user-name "$1" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text) || return 1
  for key in $keys; do
    aws iam delete-access-key --user-name "$1" --access-key-id "$key" || return 1
  done
  # Missing when init-aws.sh stopped before it; delete-user fails below if it's really still there.
  aws iam delete-user-policy --user-name "$1" --policy-name bucket 2> /dev/null
  aws iam delete-user --user-name "$1" && log__info "deleted the IAM user $1"
}

main() {
  local file name region answer failed=false
  file=$(aws__state_file)
  [[ -f $file ]] || log__fatal "$file not found: s3/init-aws.sh created nothing to destroy"
  if ! name=$(aws__state .bucket) || ! region=$(aws__state .region); then
    log__fatal "can't read $file"
  fi
  # Only what init-aws.sh creates.
  if [[ ! $name =~ $(aws__name_pattern) || $(aws__state .user) != "$name" ]]; then
    log__fatal "refusing: $file lists resources s3/init-aws.sh doesn't create"
  fi
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    log__fatal "the AWS CLI has no working credentials (aws configure, or set AWS_PROFILE)"
  fi

  printf '%s\n' "These will be deleted:" "  bucket $name ($region), with every object in it" \
    "  IAM user $name, with its policy and access keys" >&2
  read -r -p "Type Y to delete them: " answer
  [[ $answer == Y ]] || log__fatal "nothing deleted"
  s3_destroy__bucket "$name" "$region" || failed=true
  s3_destroy__user "$name" || failed=true

  # Kept until everything is gone, so a rerun finishes the job.
  $failed && log__fatal "not everything was deleted; rerun s3/destroy-aws.sh"
  rm -f "$file"
  log__info "removed $file"
}

main "$@"
