#!/usr/bin/env bash
set -euo pipefail
: "${S3_ENDPOINT:?Set the public HTTPS S3 endpoint}"
: "${S3_BUCKET:?Set a new unique test bucket name}"
: "${AWS_ACCESS_KEY_ID:?Set S3 access key in environment}"
: "${AWS_SECRET_ACCESS_KEY:?Set S3 secret key in environment}"
: "${AWS_DEFAULT_REGION:?Set the S3 region}"
[[ "$S3_ENDPOINT" =~ ^https://[a-zA-Z0-9.-]+(:443)?$ ]] || { echo 'S3_ENDPOINT must be an HTTPS origin on port 443, without a path or userinfo' >&2; exit 1; }
[[ "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo 'Invalid bucket name' >&2; exit 1; }
command -v aws >/dev/null || { echo 'AWS CLI required' >&2; exit 1; }
case "${1:-}" in
  create)
    aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$S3_BUCKET"
    printf 'VK Cloud segmentation spike test object\n' | aws --endpoint-url "$S3_ENDPOINT" s3 cp - "s3://$S3_BUCKET/spike.txt"
    ;;
  destroy)
    [[ "${CONFIRM_S3_BUCKET:-}" == "$S3_BUCKET" ]] || { echo 'Set CONFIRM_S3_BUCKET to the exact dedicated bucket name' >&2; exit 1; }
    aws --endpoint-url "$S3_ENDPOINT" s3api delete-object --bucket "$S3_BUCKET" --key spike.txt
    aws --endpoint-url "$S3_ENDPOINT" s3api delete-bucket --bucket "$S3_BUCKET"
    ;;
  *) echo "Usage: $0 create|destroy" >&2; exit 2;;
esac
