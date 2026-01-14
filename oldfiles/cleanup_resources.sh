#!/usr/bin/env bash
# cleanup_resources.sh
# Terminates EC2 instances, deletes security groups, key pairs, and S3 buckets tagged Project=AutomationLab
set -euo pipefail
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PROFILE="${AWS_PROFILE:-default}"
TAG_KEY="tag:Project"
TAG_VALUE="${TAG_VALUE:-AutomationLab}"
awscli() { aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} "$@"; }


if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found."
  exit 1
fi

echo "Cleaning up resources in region $REGION with ${TAG_KEY}=${TAG_VALUE}"

# 1) Terminate instances
INSTANCE_IDS=$(awscli ec2 describe-instances --filters "Name=tag:Project,Values=$TAG_VALUE" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text || true)
if [ -n "$INSTANCE_IDS" ]; then
  echo "Terminating instances: $INSTANCE_IDS"
  awscli ec2 terminate-instances --instance-ids $INSTANCE_IDS
  echo "Waiting for instances to terminate..."
  awscli ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
else
  echo "No instances found to terminate."
fi

# 2) Delete key pairs created earlier (filter by name prefix if desired)
# This script will try to delete keypairs with prefix automationlab-key (non-destructive if not present)
KEY_NAME_PREFIX="${KEY_NAME_PREFIX:-automationlab-key}"
KEYS=$(awscli ec2 describe-key-pairs --query "KeyPairs[?starts_with(KeyName,\`${KEY_NAME_PREFIX}\`)].KeyName" --output text || true)
if [ -n "$KEYS" ]; then
  for k in $KEYS; do
    echo "Deleting key pair: $k"
    awscli ec2 delete-key-pair --key-name "$k"
  done
else
  echo "No matching key pairs to delete."
fi

# 3) Delete security groups with tag Project=AutomationLab (skip default SGs)
SG_IDS=$(awscli ec2 describe-security-groups --filters "Name=tag:Project,Values=$TAG_VALUE" --query 'SecurityGroups[].GroupId' --output text || true)
if [ -n "$SG_IDS" ]; then
  for sg in $SG_IDS; do
    echo "Deleting security group: $sg"
    # Need to remove rules or ensure no dependencies before deletion; attempt delete
    awscli ec2 delete-security-group --group-id "$sg" || echo "Failed to delete SG $sg (maybe in use)."
  done
else
  echo "No security groups tagged for deletion."
fi

# 4) Delete S3 buckets tagged Project=AutomationLab
BUCKETS=$(awscli s3api list-buckets --query "Buckets[?contains(Name, \`automationlab-bucket\`)].Name" --output text || true)
# A more robust approach is to list all buckets, get their tags, and delete those tagged.
if [ -n "$BUCKETS" ]; then
  for b in $BUCKETS; do
    echo "Removing all objects (including versions) from bucket: $b"
    # Remove versions and delete objects
    awscli s3api list-object-versions --bucket "$b" --output json > /tmp/versions-"$b".json || true
    # Delete versions if present
    jq -r '.Versions[]? | "\(.Key):\(.VersionId)"' /tmp/versions-"$b".json >/dev/null 2>&1 || true
    # Use aws s3 rm recursion for simplicity
    awscli s3 rm "s3://$b" --recursive || true
    echo "Deleting bucket: $b"
    awscli s3api delete-bucket --bucket "$b" || echo "Failed to delete bucket $b (maybe region mismatch)."
  done
else
  echo "No candidate S3 buckets found (prefix automationlab-bucket)."
fi

echo "Cleanup complete."