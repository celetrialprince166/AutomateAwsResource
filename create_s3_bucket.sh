#!/usr/bin/env bash

# create_s3_bucket.sh 
# Creates a uniquely named S3 bucket, enables versions , sets a simple policy , uploads welcome.txt
set -euo pipefail

# Basic script identity (used by logging)
SCRIPT_NAME_OVERRIDE="create_s3_bucket.sh"

# Source logging helper (must be in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/logging.sh"

log_debug "Starting script with LOG_LEVEL=${LOG_LEVEL:-INFO}"

REGION="${AWS_REGION:-${AWS_DEFAULT:-us-east-1}}"
PROFILE="${AWS_PROFILE:-default}"
BUCKET_PREFIX="${BUCKET_PREFIX:-automationlab-bucket}"
TIMESTAMP=$(date +%s)
BUCKET_NAME="${BUCKET_NAME:-${BUCKET_PREFIX}-${TIMESTAMP}}"
TAG_KEY="Project"
TAG_VALUE="${TAG_VALUE:-AutomationLab}"

awscli() { aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} "$@"; }

if ! command -v aws >/dev/null 2>&1; then
  log_error "aws CLI not found. Please install the aws CLI and try again."
  exit 1
fi

log_info "Creating S3 bucket: ${BUCKET_NAME} in region ${REGION}"

# Create bucket (special case for us-east-1)
log_info "Creating bucket ${BUCKET_NAME} in region ${REGION}"
if [ "$REGION" = "us-east-1" ]; then
    awscli s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null
else
    awscli s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi
log_info "Bucket created: ${BUCKET_NAME}"

# Enable versioning
log_info "Enabling versioning for bucket ${BUCKET_NAME}"
awscli s3api put-bucket-versioning --bucket "$BUCKET_NAME" --versioning-configuration Status=Enabled
log_info "Versioning enabled for ${BUCKET_NAME}"
read -r -d '' POLICY <<EOF || true
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"AllowPublicReadGetObject",
      "Effect":"Allow",
      "Principal":"*",
      "Action":["s3:GetObject"],
      "Resource":["arn:aws:s3:::${BUCKET_NAME}/*"]
    }
  ]
}
EOF

# WARNING: making bucket public is often not desired in production. This is a simple example.
log_warn "Applying public read policy to bucket ${BUCKET_NAME} (not recommended for production)"
awscli s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$POLICY"
log_info "Bucket policy applied (public read) for ${BUCKET_NAME}"

log_info "Creating welcome.txt file"
echo "Welcome to Automation Lab" > welcome.txt
log_info "Uploading welcome.txt to s3://${BUCKET_NAME}/welcome.txt"
awscli s3 cp welcome.txt "s3://${BUCKET_NAME}/welcome.txt"
log_info "Uploaded welcome.txt to s3://${BUCKET_NAME}/welcome.txt"

# Add tag to the bucket
log_info "Applying tag ${TAG_KEY}=${TAG_VALUE} to bucket ${BUCKET_NAME}"
awscli s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "TagSet=[{Key=${TAG_KEY},Value=${TAG_VALUE}}]"
log_info "Tag applied successfully to bucket ${BUCKET_NAME}"
echo
echo "=== S3 Bucket Info ==="
awscli s3api get-bucket-location --bucket "$BUCKET_NAME"
awscli s3api get-bucket-versioning --bucket "$BUCKET_NAME"
awscli s3api get-bucket-tagging --bucket "$BUCKET_NAME" || true
echo "======================="

log_info "S3 bucket provisioning completed successfully for bucket=${BUCKET_NAME}"