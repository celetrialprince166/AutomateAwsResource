#!/usr/bin/env bash

# Create a new EC2 instance and a key pair (Amazon Linux 2). Prints instance ID and IP address.

set -euo pipefail

# Basic script identity (used by logging)
SCRIPT_NAME_OVERRIDE="create_ec2.sh"

# Source logging helper (must be in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/logging.sh"

log_debug "Starting script with LOG_LEVEL=${LOG_LEVEL:-INFO}"

# Default variables
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PROFILE="${AWS_PROFILE:-default}"
KEY_NAME="${KEY_NAME:-automationlab-key}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
TAG_NAME="${TAG_NAME:-Automationlab-instance}"
TAG_KEY="Project"
AMI_SSM_PARAMETER_NAME="${AMI_SSM_PARAMETER_NAME:-/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2}"

# Helper function for the CLI with region/profile
awscli() {
    aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} "$@"
}

# Check aws command is available
if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not found. Please install the aws CLI and try again."
    exit 1
fi

log_info "Using Region=${REGION}, Profile=${PROFILE}"

# Create a new key pair
if awscli ec2 describe-key-pairs --key-name "$KEY_NAME" &> /dev/null; then
    log_info "Key pair ${KEY_NAME} already exists; reusing existing key pair."
else
    log_info "Creating new key pair ${KEY_NAME}"
    awscli ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query "KeyMaterial" \
        --output text >"$KEY_NAME.pem"
    chmod 600 "$KEY_NAME.pem"
    log_info "Saved private key to ${KEY_NAME}.pem (chmod 600)"
fi

# Resolve Latest Amazon Linux 2 AMI ID from SSM Parameter Store
# we use awscli function so we always use the correct region and profile
log_info "Resolving latest Amazon Linux 2 AMI ID from SSM parameter: ${AMI_SSM_PARAMETER_NAME}"
AMI_ID=$(awscli ssm get-parameter --name "$AMI_SSM_PARAMETER_NAME" --query "Parameter.Value" --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    log_error "Failed to resolve AMI ID from SSM Parameter Store"
    exit 1
fi
log_info "Using AMI ID: ${AMI_ID}"

# Launch the EC2 instance
log_info "Launching EC2 instance type=${INSTANCE_TYPE} key_name=${KEY_NAME} tag=${TAG_KEY}=${TAG_NAME}"
RUN_OUT=$(awscli ec2 run-instances \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_NAME}]" \
    --query "Instances[0].InstanceId" \
    --output text)

INSTANCE_ID="$RUN_OUT"
log_info "Launched EC2 instance with ID: ${INSTANCE_ID}"

# Wait for the instance to be running
log_info "Waiting for instance ${INSTANCE_ID} to reach 'running' state..."
awscli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
log_info "Instance ${INSTANCE_ID} is now running."

# Get the public IP address
PUBLIC_IP=$(awscli ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
log_info "Resolved public IP address for ${INSTANCE_ID}: ${PUBLIC_IP}"

# Print the instance ID and public IP address (user-facing summary)
echo "================================================"
echo "EC2 Instance Details"
echo "================================================"
echo "Instance ID: $INSTANCE_ID"
echo "Public IP Address: $PUBLIC_IP"
echo "Key Pair: $KEY_NAME.pem"
echo "Instance Type: $INSTANCE_TYPE"
echo "AMI ID: $AMI_ID"
echo "Region: $REGION"
echo "Profile: $PROFILE"
echo "Tag Name: $TAG_NAME"
echo "Tag Key: $TAG_KEY"
echo "AMI SSM Parameter Name: $AMI_SSM_PARAMETER_NAME"
echo "================================================"

log_info "EC2 provisioning completed successfully for instance ${INSTANCE_ID}"

