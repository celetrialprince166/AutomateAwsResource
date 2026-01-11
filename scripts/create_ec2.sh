#!/usr/bin/env bash
#
# create_ec2.sh - Create and configure an AWS EC2 Instance
#
# Creates an EC2 instance using Amazon Linux 2 AMI with:
#   - Auto-generated SSH key pair (or reuses existing)
#   - Attached security group (from state or environment)
#   - Proper project tagging for resource management
#
# Dependencies:
#   - AWS CLI v2
#   - lib/common.sh (provides logging, AWS helpers, state management)
#   - Security group should be created first (see create_security_group.sh)
#
# Environment Variables:
#   AWS_REGION          - Target AWS region (default: us-east-1)
#   AWS_PROFILE         - AWS CLI profile (default: default)
#   KEY_NAME            - SSH key pair name (default: automationlab-key)
#   INSTANCE_TYPE       - EC2 instance type (default: t3.micro)
#   SG_ID               - Security group ID (default: from state file)
#
# Outputs:
#   - Creates/reuses SSH key pair, saves .pem file
#   - Launches EC2 instance with security group attached
#   - Updates state file with instance details
#   - Prints instance ID and public IP
#
# Exit Codes:
#   0 - Success
#   1 - Prerequisites failed
#   2 - AWS API error
#   3 - State file error
#   4 - Security group not found
#
# Example:
#   ./scripts/create_ec2.sh
#   INSTANCE_TYPE=t3.micro ./scripts/create_ec2.sh
#
# Author: AutomationLab Project
# Version: 2.0.0
#

set -euo pipefail

# ============================================================================
# Script Initialization
# ============================================================================

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source the common library (loads config, logging, state, validation)
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"

# Source state management
# shellcheck source=../lib/state.sh
source "${PROJECT_ROOT}/lib/state.sh"

# Source validation helpers
# shellcheck source=../lib/validation.sh
source "${PROJECT_ROOT}/lib/validation.sh"

# Initialize script (validates prerequisites, sets up logging)
init_script

# ============================================================================
# Configuration
# ============================================================================

# EC2 settings from config.env (via common.sh)
EC2_KEY_NAME="${KEY_NAME}"
EC2_INSTANCE_TYPE="${INSTANCE_TYPE}"
EC2_INSTANCE_NAME="${INSTANCE_NAME}"
AMI_SSM_PARAM="${AMI_SSM_PARAMETER}"

# Security group ID (can be passed via env or read from state)
SG_ID="${SG_ID:-}"

# Key pair file location
KEY_FILE="${PROJECT_ROOT}/${EC2_KEY_NAME}.pem"

# ============================================================================
# Functions
# ============================================================================

# Get security group ID from state or fail
get_security_group_id() {
    # First check if passed via environment
    if [[ -n "${SG_ID}" ]]; then
        log_debug "Using security group from environment: ${SG_ID}"
        echo "${SG_ID}"
        return 0
    fi
    
    # Try to get from state file
    if state_has_resource "security_group"; then
        local sg_id
        sg_id=$(state_get_resource_field "security_group" "id")
        local sg_status
        sg_status=$(state_get_resource_field "security_group" "status")
        
        if [[ "${sg_status}" == "created" ]] && [[ -n "${sg_id}" ]]; then
            log_debug "Using security group from state: ${sg_id}"
            echo "${sg_id}"
            return 0
        fi
    fi
    
    log_error "No security group found!"
    log_error "Run create_security_group.sh first, or set SG_ID environment variable"
    return 1
}

# Check if key pair exists
key_pair_exists() {
    local key_name="$1"
    aws_cmd ec2 describe-key-pairs --key-names "${key_name}" &>/dev/null
}

# Create new key pair and save private key
create_key_pair() {
    local key_name="$1"
    local key_file="$2"
    
    log_info "Creating new SSH key pair: ${key_name}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would create key pair: ${key_name}"
        return 0
    fi
    
    # Create key pair and save private key
    aws_cmd ec2 create-key-pair \
        --key-name "${key_name}" \
        --query "KeyMaterial" \
        --output text > "${key_file}"
    
    # Set secure permissions (handled gracefully on Windows)
    safe_chmod 600 "${key_file}"
    
    log_success "Key pair created and saved to: ${key_file}"
    
    # Update state
    local key_json
    key_json=$(state_key_pair_json "${key_name}" "${key_file}")
    state_set_resource "key_pair" "${key_json}"
}

# Get latest Amazon Linux 2 AMI ID from SSM Parameter Store
get_latest_ami_id() {
    log_info "Resolving latest Amazon Linux 2 AMI from SSM..."
    log_debug "SSM Parameter: ${AMI_SSM_PARAM}"
    
    local ami_id
    ami_id=$(aws_cmd ssm get-parameter \
        --name "${AMI_SSM_PARAM}" \
        --query "Parameter.Value" \
        --output text | tr -d '\r\n' | xargs)
    
    if [[ -z "${ami_id}" ]] || [[ "${ami_id}" == "None" ]]; then
        log_error "Failed to resolve AMI ID from SSM Parameter Store"
        log_error "Parameter: ${AMI_SSM_PARAM}"
        return 1
    fi
    
    # Validate AMI ID format
    validate_ami_id "${ami_id}" || return 1
    
    log_info "Using AMI: ${ami_id}"
    echo "${ami_id}"
}

# Launch EC2 instance
launch_instance() {
    local ami_id="$1"
    local instance_type="$2"
    local key_name="$3"
    local sg_id="$4"
    local instance_name="$5"
    
    log_info "Launching EC2 instance..."
    log_kv "AMI ID" "${ami_id}"
    log_kv "Instance Type" "${instance_type}"
    log_kv "Key Pair" "${key_name}"
    log_kv "Security Group" "${sg_id}"
    log_kv "Name" "${instance_name}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would launch EC2 instance"
        echo "i-dryrun12345"
        return 0
    fi
    
    # Build tag specification
    # Include both Name tag (for console display) and Project tag (for management)
    local tag_spec="ResourceType=instance,Tags=["
    tag_spec+="{Key=Name,Value=${instance_name}},"
    tag_spec+="{Key=${TAG_KEY},Value=${PROJECT_TAG}}"
    tag_spec+="]"
    
    local instance_id
    instance_id=$(aws_cmd ec2 run-instances \
        --image-id "${ami_id}" \
        --count 1 \
        --instance-type "${instance_type}" \
        --key-name "${key_name}" \
        --security-group-ids "${sg_id}" \
        --tag-specifications "${tag_spec}" \
        --query "Instances[0].InstanceId" \
        --output text | tr -d '\r\n' | xargs)
    
    if [[ -z "${instance_id}" ]] || [[ "${instance_id}" == "None" ]]; then
        log_error "Failed to launch EC2 instance"
        return 1
    fi
    
    log_success "Instance launched: ${instance_id}"
    echo "${instance_id}"
}

# Wait for instance to be running
wait_for_instance() {
    local instance_id="$1"
    
    log_info "Waiting for instance ${instance_id} to reach 'running' state..."
    
    if is_dry_run; then
        log_info "[DRY RUN] Would wait for instance"
        return 0
    fi
    
    aws_cmd ec2 wait instance-running --instance-ids "${instance_id}"
    
    log_success "Instance ${instance_id} is now running"
}

# Get instance public IP address
get_public_ip() {
    local instance_id="$1"
    
    log_debug "Retrieving public IP for instance ${instance_id}..."
    
    local public_ip
    public_ip=$(aws_cmd ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text | tr -d '\r\n' | xargs)
    
    if [[ "${public_ip}" == "None" ]] || [[ -z "${public_ip}" ]]; then
        log_warn "No public IP assigned to instance"
        log_warn "Instance may be in a private subnet or public IP assignment is disabled"
        echo "N/A"
    else
        echo "${public_ip}"
    fi
}

# ============================================================================
# Main Logic
# ============================================================================

main() {
    log_info "Starting EC2 instance creation..."
    log_separator "-"
    
    # Initialize state
    state_init
    
    # Check if we already have an instance in state
    if state_has_resource "ec2_instance"; then
        local existing_id
        existing_id=$(state_get_resource_field "ec2_instance" "id")
        local existing_status
        existing_status=$(state_get_resource_field "ec2_instance" "status")
        
        if [[ "${existing_status}" == "created" ]] && [[ -n "${existing_id}" ]]; then
            log_info "EC2 instance already exists in state: ${existing_id}"
            
            # Verify it still exists in AWS
            local instance_state
            instance_state=$(aws_cmd ec2 describe-instances \
                --instance-ids "${existing_id}" \
                --query "Reservations[0].Instances[0].State.Name" \
                --output text 2>/dev/null || echo "not-found")
            
            if [[ "${instance_state}" != "not-found" ]] && [[ "${instance_state}" != "terminated" ]]; then
                log_info "Instance is in state: ${instance_state}"
                local public_ip
                public_ip=$(get_public_ip "${existing_id}")
                
                print_summary "Existing EC2 Instance" \
                    "Instance ID:${existing_id}" \
                    "State:${instance_state}" \
                    "Public IP:${public_ip}"
                
                echo "INSTANCE_ID=${existing_id}"
                echo "PUBLIC_IP=${public_ip}"
                return 0
            else
                log_warn "Instance in state no longer exists or is terminated, will recreate"
            fi
        fi
    fi
    
    # CRITICAL: Get security group ID
    local sg_id
    sg_id=$(get_security_group_id) || exit 4
    log_info "Using security group: ${sg_id}"
    
    # Validate security group exists
    if ! is_dry_run; then
        if ! aws_cmd ec2 describe-security-groups --group-ids "${sg_id}" &>/dev/null; then
            log_error "Security group ${sg_id} does not exist or is not accessible"
            exit 4
        fi
    fi
    
    # Handle key pair
    if key_pair_exists "${EC2_KEY_NAME}"; then
        log_info "Key pair '${EC2_KEY_NAME}' already exists, reusing"
        
        # Update state if not already there
        if ! state_has_resource "key_pair"; then
            local key_json
            key_json=$(state_key_pair_json "${EC2_KEY_NAME}" "${KEY_FILE}")
            state_set_resource "key_pair" "${key_json}"
        fi
        
        if [[ ! -f "${KEY_FILE}" ]]; then
            log_warn "Key pair exists in AWS but .pem file not found locally"
            log_warn "You may need to use an existing .pem file or delete the key pair and recreate"
        fi
    else
        create_key_pair "${EC2_KEY_NAME}" "${KEY_FILE}"
    fi
    
    # Get latest AMI ID
    local ami_id
    ami_id=$(get_latest_ami_id) || exit 2
    
    # Launch instance
    local instance_id
    instance_id=$(launch_instance \
        "${ami_id}" \
        "${EC2_INSTANCE_TYPE}" \
        "${EC2_KEY_NAME}" \
        "${sg_id}" \
        "${EC2_INSTANCE_NAME}") || exit 2
    
    # Wait for running state
    wait_for_instance "${instance_id}"
    
    # Get public IP
    local public_ip
    public_ip=$(get_public_ip "${instance_id}")
    
    # Update state file
    if ! is_dry_run; then
        local ec2_json
        ec2_json=$(state_ec2_json \
            "${instance_id}" \
            "${public_ip}" \
            "${ami_id}" \
            "${EC2_KEY_NAME}" \
            "${sg_id}")
        state_set_resource "ec2_instance" "${ec2_json}"
        log_debug "State updated with EC2 instance info"
    fi
    
    # Print summary
    print_summary "EC2 Instance Created" \
        "Instance ID:${instance_id}" \
        "Public IP:${public_ip}" \
        "Key Pair:${EC2_KEY_NAME}" \
        "Key File:${KEY_FILE}" \
        "Instance Type:${EC2_INSTANCE_TYPE}" \
        "AMI ID:${ami_id}" \
        "Security Group:${sg_id}" \
        "Region:${AWS_REGION}" \
        "Tag:${TAG_KEY}=${PROJECT_TAG}"
    
    # SSH connection hint
    if [[ "${public_ip}" != "N/A" ]] && [[ -f "${KEY_FILE}" ]]; then
        echo ""
        echo "Connect via SSH:"
        echo "  ssh -i ${KEY_FILE} ec2-user@${public_ip}"
        echo ""
    fi
    
    log_success "EC2 instance provisioning completed successfully"
    
    # Output for orchestration (machine-readable)
    echo "INSTANCE_ID=${instance_id}"
    echo "PUBLIC_IP=${public_ip}"
}

# Run main function
main "$@"

