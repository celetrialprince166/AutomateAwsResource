#!/usr/bin/env bash

# Create a new security group for the EC2 instance that opens port 22 for SSH traffic and HTTP traffic port 80.
# Prints security group ID and current ingress rules.

set -euo pipefail

# Basic script identity (used by logging.sh)
SCRIPT_NAME_OVERRIDE="create_security_group.sh"

# Source logging helper (must be in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/logging.sh"

log_debug "Starting script with LOG_LEVEL=${LOG_LEVEL:-INFO}"

# Default variables
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PROFILE="${AWS_PROFILE:-default}"
SG_NAME="${SECURITY_GROUP_NAME:-Automationlab-security-group}"
DESCRIPTION="${DESCRIPTION:-Security group for Automationlab instance}"
VPC_ID="${VPC_ID:-}"
TAG_KEY="${TAG_KEY:-Project}"
TAG_VALUE="${TAG_VALUE:-Automationlab}"

# Help function for the CLI with region/profile
aws_cli() { aws --region "$REGION" ${PROFILE:+--profile "$PROFILE"} "$@"; }

# Check aws command is available
if ! command -v aws >/dev/null 2>&1; then
    log_error "aws cli not found. Please install the aws cli and try again."
    exit 1
fi

log_info "Using Region=${REGION}, Profile=${PROFILE}"

# If VPC not supplied pick the default VPC of the region
if [ -z "$VPC_ID" ]; then
    log_info "No VPC_ID supplied; resolving default VPC for region ${REGION}"
    VPC_ID=$(aws_cli ec2 describe-vpcs \
        --filters Name=isDefault,Values=true \
        --query Vpcs[0].VpcId \
        --output text)

    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        log_error "No default VPC found. Please create a default VPC and try again."
        exit 1
    fi
fi

log_info "Creating or reusing security group in VPC: ${VPC_ID}"

# If security group already exists (name and vpc id match), reuse it.
EXISTING_SG_ID=$(aws_cli ec2 describe-security-groups \
    --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || true)

if [ -n "$EXISTING_SG_ID" ] && [ "$EXISTING_SG_ID" != "None" ]; then
    log_info "Security group ${SG_NAME} already exists. Reusing existing group with ID=${EXISTING_SG_ID}."
    SG_ID="$EXISTING_SG_ID"
else
    log_info "Security group ${SG_NAME} does not exist. Creating new security group."
    SG_ID=$(aws_cli ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "$DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)
    log_info "Security group ${SG_NAME} created successfully with ID=${SG_ID}."
    aws_cli ec2 create-tags --resources "$SG_ID" --tags Key="$TAG_KEY",Value="$TAG_VALUE"
    log_info "Applied tag ${TAG_KEY}=${TAG_VALUE} to security group ${SG_ID}."
fi

# Authorizing ingress for SSH (22) and HTTP (80) traffic if not already present.
# First check if present in the security group; if not, add it.
has_rule() {
    local port=$1
    aws_cli ec2 describe-security-groups --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissions[?ToPort==\`${port}\` && FromPort==\`${port}\`]" \
        --output text
}

if [ -z "$(has_rule 22)" ]; then
    aws_cli ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 || true
    log_info "Added SSH (22) ingress to security group ${SG_ID}."
else
    log_info "SSH (22) ingress already exists on security group ${SG_ID}."
fi

if [ -z "$(has_rule 80)" ]; then
    aws_cli ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 || true
    log_info "Added HTTP (80) ingress to security group ${SG_ID}."
else
    log_info "HTTP (80) ingress already exists on security group ${SG_ID}."
fi

echo
echo "=== Security Group Info ==="
aws_cli ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].{GroupId:GroupId,GroupName:GroupName,IpPermissions:IpPermissions}' \
    --output json
echo "===================="

log_info "Security group provisioning completed successfully for SG_ID=${SG_ID}."


