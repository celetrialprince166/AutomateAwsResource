#!/usr/bin/env bash
#
# create_security_group.sh - Create and configure an AWS Security Group
#
# Creates a security group in the default VPC with SSH (22) and HTTP (80) ingress
# rules. Implements idempotent behavior - reuses existing SG if found.
#
# Dependencies:
#   - AWS CLI v2
#   - lib/common.sh (provides logging, AWS helpers, state management)
#
# Environment Variables:
#   AWS_REGION              - Target AWS region (default: us-east-1)
#   AWS_PROFILE             - AWS CLI profile (default: default)
#   SECURITY_GROUP_NAME     - Name for the security group
#   VPC_ID                  - VPC ID (default: uses default VPC)
#
# Outputs:
#   - Creates security group with Project tag
#   - Opens ports 22 (SSH) and 80 (HTTP)
#   - Updates state file with SG details
#   - Prints SG ID to stdout for orchestration
#
# Exit Codes:
#   0 - Success
#   1 - Prerequisites failed
#   2 - AWS API error
#   3 - State file error
#
# Example:
#   ./scripts/create_security_group.sh
#   SECURITY_GROUP_NAME=my-sg ./scripts/create_security_group.sh
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

# Security group settings from config.env (via common.sh)
SG_NAME="${SECURITY_GROUP_NAME}"
SG_DESC="${SECURITY_GROUP_DESC}"
SSH_PORT="${SG_SSH_PORT}"
HTTP_PORT="${SG_HTTP_PORT}"
INGRESS_CIDR="${SG_INGRESS_CIDR}"

# VPC can be overridden, otherwise use default
VPC_ID="${VPC_ID:-}"

# ============================================================================
# Functions
# ============================================================================

# Check if security group already exists
# Returns: SG ID if exists, empty string if not
find_existing_sg() {
    local sg_name="$1"
    local vpc_id="$2"
    
    log_debug "Checking for existing security group: ${sg_name} in VPC ${vpc_id}" >&2
    
    local sg_id
    sg_id=$(aws_cmd ec2 describe-security-groups \
        --filters "Name=group-name,Values=${sg_name}" "Name=vpc-id,Values=${vpc_id}" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>/dev/null || echo "")
    
    # Clean the SG ID - remove ALL whitespace and control characters
    sg_id=$(echo "${sg_id}" | tr -d '[:space:]' | tr -d '\r\n')
    
    # Handle "None" response
    if [[ "${sg_id}" == "None" ]] || [[ -z "${sg_id}" ]]; then
        echo ""
    else
        echo "${sg_id}"
    fi
}

# Check if an ingress rule exists for a specific port
has_ingress_rule() {
    local sg_id="$1"
    local port="$2"
    
    local result
    result=$(aws_cmd ec2 describe-security-groups \
        --group-ids "${sg_id}" \
        --query "SecurityGroups[0].IpPermissions[?ToPort==\`${port}\` && FromPort==\`${port}\`]" \
        --output text 2>/dev/null || echo "")
    
    [[ -n "${result}" ]]
}

# Add ingress rule for a port
add_ingress_rule() {
    local sg_id="$1"
    local port="$2"
    local protocol="${3:-tcp}"
    local cidr="${4:-0.0.0.0/0}"
    local description="${5:-}"
    
    log_debug "Adding ingress rule: port ${port}/${protocol} from ${cidr}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would check/add ingress: port ${port}/${protocol} from ${cidr}"
        return 0
    fi
    
    if has_ingress_rule "${sg_id}" "${port}"; then
        log_info "Port ${port} ingress rule already exists"
        return 0
    fi
    
    aws_cmd ec2 authorize-security-group-ingress \
        --group-id "${sg_id}" \
        --protocol "${protocol}" \
        --port "${port}" \
        --cidr "${cidr}" >/dev/null
    
    log_success "Added ingress rule: port ${port}/${protocol} from ${cidr}"
}

# Create new security group
create_security_group() {
    local sg_name="$1"
    local description="$2"
    local vpc_id="$3"
    
    log_info "Creating new security group: ${sg_name}" >&2
    
    if is_dry_run; then
        log_info "[DRY RUN] Would create security group: ${sg_name}" >&2
        echo "sg-dryrun12345"
        return 0
    fi
    
    local sg_id
    sg_id=$(aws_cmd ec2 create-security-group \
        --group-name "${sg_name}" \
        --description "${description}" \
        --vpc-id "${vpc_id}" \
        --query "GroupId" \
        --output text 2>/dev/null)
    
    # Clean the SG ID - remove ALL whitespace and control characters
    sg_id=$(echo "${sg_id}" | tr -d '[:space:]' | tr -d '\r\n')
    
    if [[ -z "${sg_id}" ]]; then
        log_error "Failed to create security group" >&2
        return 1
    fi
    
    log_success "Created security group: ${sg_id}" >&2
    
    # Apply project tags (redirect output to stderr)
    if ! is_dry_run; then
        log_debug "Applying tags: ${TAG_KEY}=${PROJECT_TAG}" >&2
        apply_tags "${sg_id}" "ec2" >/dev/null 2>&1
    fi
    
    # Output ONLY the clean SG ID to stdout
    echo "${sg_id}"
}

# Display security group information
display_sg_info() {
    local sg_id="$1"
    
    if is_dry_run; then
        return 0
    fi
    
    log_info "Retrieving security group details..."
    
    echo ""
    echo "=== Security Group Info ==="
    aws_cmd ec2 describe-security-groups \
        --group-ids "${sg_id}" \
        --query 'SecurityGroups[0].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId,Description:Description,IpPermissions:IpPermissions}' \
        --output json
    echo "==========================="
    echo ""
}

# ============================================================================
# Main Logic
# ============================================================================

main() {
    log_info "Starting security group creation..."
    log_separator "-"
    
    # Initialize state
    state_init
    
    # Check if we already have this resource in state
    if state_has_resource "security_group"; then
        local existing_sg_id
        existing_sg_id=$(state_get_resource_field "security_group" "id")
        local existing_status
        existing_status=$(state_get_resource_field "security_group" "status")
        
        if [[ "${existing_status}" == "created" ]] && [[ -n "${existing_sg_id}" ]]; then
            log_info "Security group already exists in state: ${existing_sg_id}"
            
            # Verify it still exists in AWS
            if aws_cmd ec2 describe-security-groups --group-ids "${existing_sg_id}" &>/dev/null; then
                log_success "Verified security group exists in AWS"
                display_sg_info "${existing_sg_id}"
                # Output for orchestration
                echo "SG_ID=${existing_sg_id}"
                return 0
            else
                log_warn "Security group in state no longer exists in AWS, will recreate"
            fi
        fi
    fi
    
    # Get VPC ID (use default if not specified)
    if [[ -z "${VPC_ID}" ]]; then
        VPC_ID=$(get_default_vpc) || exit 1
    else
        # Validate provided VPC ID
        validate_vpc_id "${VPC_ID}" || exit 1
    fi
    log_info "Using VPC: ${VPC_ID}"
    
    # Check for existing security group (idempotent behavior)
    local sg_id
    sg_id=$(find_existing_sg "${SG_NAME}" "${VPC_ID}")
    
    if [[ -n "${sg_id}" ]]; then
        log_info "Security group '${SG_NAME}' already exists: ${sg_id}"
        log_info "Reusing existing security group"
    else
        # Create new security group
        sg_id=$(create_security_group "${SG_NAME}" "${SG_DESC}" "${VPC_ID}") || exit 1
    fi
    
    # CRITICAL: Clean the SG ID to remove any whitespace/newlines
    sg_id=$(echo "${sg_id}" | tr -d '[:space:]')
    
    log_debug "Using security group ID: [${sg_id}]"
    
    # Validate SG ID format
    if ! is_dry_run; then
        validate_security_group_id "${sg_id}" || exit 1
    fi
    
    # Ensure required ingress rules exist
    log_info "Configuring ingress rules..."
    
    # Add SSH rule (port 22)
    add_ingress_rule "${sg_id}" "${SSH_PORT}" "tcp" "${INGRESS_CIDR}" "SSH access"
    
    # Add HTTP rule (port 80)
    add_ingress_rule "${sg_id}" "${HTTP_PORT}" "tcp" "${INGRESS_CIDR}" "HTTP access"
    
    # Update state file
    if ! is_dry_run; then
        local sg_json
        sg_json=$(state_security_group_json "${sg_id}" "${SG_NAME}" "${VPC_ID}")
        state_set_resource "security_group" "${sg_json}"
        log_debug "State updated with security group info"
    fi
    
    # Display final info
    display_sg_info "${sg_id}"
    
    # Print summary
    print_summary "Security Group Created" \
        "Group ID:${sg_id}" \
        "Group Name:${SG_NAME}" \
        "VPC ID:${VPC_ID}" \
        "SSH Port:${SSH_PORT}" \
        "HTTP Port:${HTTP_PORT}" \
        "Region:${AWS_REGION}" \
        "Tag:${TAG_KEY}=${PROJECT_TAG}"
    
    log_success "Security group provisioning completed successfully"
    
    # Output for orchestration (machine-readable)
    echo "SG_ID=${sg_id}"
}

# Run main function
main "$@"

