#!/usr/bin/env bash
#
# orchestrate.sh - Main Entry Point for AWS Resource Automation
#
# This script orchestrates the creation and cleanup of all AWS resources
# in the correct dependency order. It provides a unified interface for
# all operations.
#
# Commands:
#   apply     - Create all resources (security group -> EC2 -> S3)
#   destroy   - Clean up all resources
#   plan      - Show what would be created/destroyed (dry-run)
#   status    - Show current state
#   verify    - Validate created resources
#
# Options:
#   --auto-approve    Skip confirmation prompts
#   --verbose, -v     Enable debug logging
#   --dry-run         Show what would be done without doing it
#   --help, -h        Show this help message
#
# Examples:
#   ./orchestrate.sh apply                    # Create all resources
#   ./orchestrate.sh apply --auto-approve     # Create without prompts
#   ./orchestrate.sh plan                     # Preview what would be created
#   ./orchestrate.sh destroy                  # Clean up all resources
#   ./orchestrate.sh status                   # Show current state
#
# Author: AutomationLab Project
# Version: 2.0.0
#

set -euo pipefail

# ============================================================================
# Script Setup
# ============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Scripts directory
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# Source the common library
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"

# ============================================================================
# Failure Tracking
# ============================================================================

# Track if we're in the middle of apply
APPLY_IN_PROGRESS=false
LAST_COMPLETED_STEP=""
FAILED_STEP=""

# Cleanup handler for failures during apply
handle_apply_failure() {
    local exit_code=$?
    
    if [[ "${APPLY_IN_PROGRESS}" == "true" ]] && [[ ${exit_code} -ne 0 ]]; then
        echo ""
        log_separator "!"
        log_error "APPLY FAILED at step: ${FAILED_STEP:-unknown}"
        log_separator "!"
        echo ""
        echo "What happened:"
        echo "  - Last successful step: ${LAST_COMPLETED_STEP:-none}"
        echo "  - Failed step: ${FAILED_STEP:-unknown}"
        echo ""
        echo "Resources may have been partially created. To recover:"
        echo ""
        echo "  Option 1: Fix the issue and re-run"
        echo "    ./orchestrate.sh apply"
        echo "    (Idempotent - will skip already-created resources)"
        echo ""
        echo "  Option 2: Clean up and start fresh"
        echo "    ./orchestrate.sh destroy"
        echo "    ./orchestrate.sh apply"
        echo ""
        echo "  Option 3: Check current state"
        echo "    ./orchestrate.sh status"
        echo ""
        
        # Show what's in the state
        if [[ -f "${STATE_FILE}" ]]; then
            log_info "Current state file contents:"
            state_show
        fi
    fi
    
    exit ${exit_code}
}

# Set trap for apply failures
trap handle_apply_failure EXIT

# ============================================================================
# Help Message
# ============================================================================

show_help() {
    cat << 'EOF'

========================================================================
           AWS Resource Automation - AutomationLab Project
========================================================================

USAGE:
    ./orchestrate.sh <command> [options]

COMMANDS:
    apply       Create all AWS resources in correct order
                (Security Group -> EC2 Instance -> S3 Bucket)

    destroy     Clean up all resources (uses state file for accuracy)

    plan        Preview what would be created or destroyed
                (same as apply/destroy with --dry-run)

    status      Show current state of resources

    verify      Check that created resources exist and are accessible

    help        Show this help message

OPTIONS:
    --auto-approve    Skip all confirmation prompts
    --verbose, -v     Enable debug logging (LOG_LEVEL=DEBUG)
    --dry-run         Show actions without executing them
    --help, -h        Show this help message

ENVIRONMENT VARIABLES:
    AWS_REGION        Target AWS region (default: us-east-1)
    AWS_PROFILE       AWS CLI profile to use (default: default)
    AUTO_APPROVE      Set to 'true' to skip prompts
    LOG_LEVEL         Logging level: DEBUG, INFO, WARN, ERROR

EXAMPLES:
    # Create all resources interactively
    ./orchestrate.sh apply

    # Create without prompts (for CI/CD)
    ./orchestrate.sh apply --auto-approve

    # Preview what would be created
    ./orchestrate.sh plan

    # Use a different region
    AWS_REGION=eu-west-1 ./orchestrate.sh apply

    # Enable verbose logging
    ./orchestrate.sh apply --verbose

    # Clean up everything
    ./orchestrate.sh destroy

FAILURE RECOVERY:
    If apply fails mid-way:
    1. Check status:  ./orchestrate.sh status
    2. Fix the issue (check AWS console/logs)
    3. Re-run:        ./orchestrate.sh apply  (idempotent, skips completed steps)
    
    Or clean up and start fresh:
    ./orchestrate.sh destroy && ./orchestrate.sh apply

For more information, see README.md

EOF
}

# ============================================================================
# Command: Apply (Create Resources)
# ============================================================================

cmd_apply() {
    APPLY_IN_PROGRESS=true
    
    log_info "Starting resource provisioning..."
    log_separator "="
    log_kv "Region" "${AWS_REGION}"
    log_kv "Profile" "${AWS_PROFILE}"
    log_kv "Project Tag" "${PROJECT_TAG}"
    log_separator "="
    echo ""
    
    # Initialize state
    state_init
    
    # Confirmation
    if ! is_dry_run && [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
        if ! confirm "This will create AWS resources. Continue?"; then
            log_info "Operation cancelled by user"
            APPLY_IN_PROGRESS=false
            exit 0
        fi
        echo ""
    fi
    
    local start_time
    start_time=$(date +%s)
    
    # Step 1: Create Security Group
    FAILED_STEP="Security Group"
    log_separator "-"
    log_step 1 3 "Creating Security Group"
    log_separator "-"
    
    local sg_output
    sg_output=$(bash "${SCRIPTS_DIR}/create_security_group.sh" 2>&1) || {
        echo "${sg_output}"
        log_error "Failed to create security group"
        exit 1
    }
    echo "${sg_output}"
    
    # Extract SG_ID from output (format: SG_ID=sg-xxx)
    local sg_id
    sg_id=$(echo "${sg_output}" | grep -o 'SG_ID=sg-[a-f0-9]*' | cut -d= -f2 | tail -1)
    if [[ -z "${sg_id}" ]]; then
        log_error "Could not extract Security Group ID from output"
        exit 1
    fi
    log_debug "Captured SG_ID: ${sg_id}"
    export SG_ID="${sg_id}"
    
    LAST_COMPLETED_STEP="Security Group"
    echo ""
    
    # Step 2: Create EC2 Instance (pass SG_ID explicitly)
    FAILED_STEP="EC2 Instance"
    log_separator "-"
    log_step 2 3 "Creating EC2 Instance"
    log_separator "-"
    
    local ec2_output
    ec2_output=$(SG_ID="${sg_id}" bash "${SCRIPTS_DIR}/create_ec2.sh" 2>&1) || {
        echo "${ec2_output}"
        log_error "Failed to create EC2 instance"
        exit 1
    }
    echo "${ec2_output}"
    LAST_COMPLETED_STEP="EC2 Instance"
    echo ""
    
    # Step 3: Create S3 Bucket
    FAILED_STEP="S3 Bucket"
    log_separator "-"
    log_step 3 3 "Creating S3 Bucket"
    log_separator "-"
    
    local s3_output
    s3_output=$(bash "${SCRIPTS_DIR}/create_s3_bucket.sh" 2>&1) || {
        echo "${s3_output}"
        log_error "Failed to create S3 bucket"
        exit 1
    }
    echo "${s3_output}"
    LAST_COMPLETED_STEP="S3 Bucket"
    FAILED_STEP=""
    echo ""
    
    # Calculate duration
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Mark apply as complete (prevent failure handler from running)
    APPLY_IN_PROGRESS=false
    
    # Final summary
    log_separator "="
    log_success "All resources created successfully!"
    log_info "Total time: ${duration} seconds"
    log_separator "="
    
    # Show state
    state_show
    
    # Show next steps
    echo ""
    echo "+---------------------------------------------------------------------+"
    echo "|                         NEXT STEPS                                 |"
    echo "+---------------------------------------------------------------------+"
    echo "|  1. Verify resources: ./orchestrate.sh verify                      |"
    echo "|  2. View state:       ./orchestrate.sh status                      |"
    echo "|  3. Clean up:         ./orchestrate.sh destroy                     |"
    echo "+---------------------------------------------------------------------+"
    echo ""
}

# ============================================================================
# Command: Destroy (Clean Up Resources)
# ============================================================================

cmd_destroy() {
    log_info "Starting resource cleanup..."
    
    if ! bash "${SCRIPTS_DIR}/cleanup_resources.sh"; then
        log_error "Cleanup failed or was cancelled"
        exit 1
    fi
}

# ============================================================================
# Command: Plan (Preview)
# ============================================================================

cmd_plan() {
    log_info "Plan Mode - Previewing what would be done"
    log_separator "="
    
    # Check what exists in state
    state_init
    
    if state_has_resources; then
        log_info "Resources exist in state - showing destroy plan:"
        DRY_RUN=true bash "${SCRIPTS_DIR}/cleanup_resources.sh"
    else
        log_info "No resources in state - showing apply plan:"
        echo ""
        echo "The following resources would be created:"
        echo ""
        echo "  1. Security Group: ${SECURITY_GROUP_NAME}"
        echo "     - VPC: (default VPC)"
        echo "     - Ports: 22 (SSH), 80 (HTTP)"
        echo "     - Tag: ${TAG_KEY}=${PROJECT_TAG}"
        echo ""
        echo "  2. EC2 Instance:"
        echo "     - Type: ${INSTANCE_TYPE}"
        echo "     - AMI: Amazon Linux 2 (latest)"
        echo "     - Key Pair: ${KEY_NAME}"
        echo "     - Tag: ${TAG_KEY}=${PROJECT_TAG}"
        echo ""
        echo "  3. S3 Bucket: ${BUCKET_PREFIX}-<timestamp>"
        echo "     - Versioning: Enabled"
        echo "     - Policy: Public Read (demo only)"
        echo "     - Sample file: welcome.txt"
        echo "     - Tag: ${TAG_KEY}=${PROJECT_TAG}"
        echo ""
        log_info "Run './orchestrate.sh apply' to create these resources"
    fi
}

# ============================================================================
# Command: Status
# ============================================================================

cmd_status() {
    log_info "Current Resource Status"
    
    # Initialize state (doesn't create if not exists)
    if [[ -f "${STATE_FILE}" ]]; then
        state_show
        
        # Also check actual AWS state
        log_info "Verifying resources in AWS..."
        
        if state_has_resource "ec2_instance"; then
            local instance_id
            instance_id=$(state_get_resource_field "ec2_instance" "id")
            local state
            state=$(aws_cmd ec2 describe-instances \
                --instance-ids "${instance_id}" \
                --query "Reservations[0].Instances[0].State.Name" \
                --output text 2>/dev/null | tr -d '\r\n' || echo "not-found")
            log_kv "EC2 (${instance_id})" "${state}"
        fi
        
        if state_has_resource "security_group"; then
            local sg_id
            sg_id=$(state_get_resource_field "security_group" "id")
            if aws_cmd ec2 describe-security-groups --group-ids "${sg_id}" &>/dev/null; then
                log_kv "Security Group (${sg_id})" "exists"
            else
                log_kv "Security Group (${sg_id})" "not found"
            fi
        fi
        
        if state_has_resource "s3_bucket"; then
            local bucket_name
            bucket_name=$(state_get_resource_field "s3_bucket" "name")
            if aws_cmd s3api head-bucket --bucket "${bucket_name}" &>/dev/null; then
                log_kv "S3 Bucket (${bucket_name})" "exists"
            else
                log_kv "S3 Bucket (${bucket_name})" "not found"
            fi
        fi
    else
        log_warn "No state file found at: ${STATE_FILE}"
        log_info "Run './orchestrate.sh apply' to create resources"
    fi
}

# ============================================================================
# Command: Verify
# ============================================================================

cmd_verify() {
    log_info "Verifying created resources..."
    log_separator "="
    
    local all_ok=true
    
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_error "No state file found - nothing to verify"
        log_info "Run './orchestrate.sh apply' first"
        exit 1
    fi
    
    # Verify EC2
    echo ""
    log_info "Checking EC2 Instance..."
    if state_has_resource "ec2_instance"; then
        local instance_id public_ip
        instance_id=$(state_get_resource_field "ec2_instance" "id")
        public_ip=$(state_get_resource_field "ec2_instance" "public_ip")
        
        local state
        state=$(aws_cmd ec2 describe-instances \
            --instance-ids "${instance_id}" \
            --query "Reservations[0].Instances[0].State.Name" \
            --output text 2>/dev/null | tr -d '\r\n' || echo "not-found")
        
        if [[ "${state}" == "running" ]]; then
            log_success "EC2 Instance ${instance_id} is running"
            log_kv "Public IP" "${public_ip}"
            
            # Try to check if SSH port is reachable (basic check)
            if command -v nc &>/dev/null && [[ "${public_ip}" != "N/A" ]]; then
                if nc -z -w5 "${public_ip}" 22 2>/dev/null; then
                    log_success "SSH port (22) is reachable"
                else
                    log_warn "SSH port (22) not reachable (may still be initializing)"
                fi
            fi
        else
            log_error "EC2 Instance ${instance_id} is ${state}"
            all_ok=false
        fi
    else
        log_warn "No EC2 instance in state"
    fi
    
    # Verify Security Group
    echo ""
    log_info "Checking Security Group..."
    if state_has_resource "security_group"; then
        local sg_id
        sg_id=$(state_get_resource_field "security_group" "id")
        
        if aws_cmd ec2 describe-security-groups --group-ids "${sg_id}" &>/dev/null; then
            log_success "Security Group ${sg_id} exists"
            
            # Check rules
            local ssh_rule http_rule
            ssh_rule=$(aws_cmd ec2 describe-security-groups \
                --group-ids "${sg_id}" \
                --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`]" \
                --output text 2>/dev/null || echo "")
            http_rule=$(aws_cmd ec2 describe-security-groups \
                --group-ids "${sg_id}" \
                --query "SecurityGroups[0].IpPermissions[?FromPort==\`80\`]" \
                --output text 2>/dev/null || echo "")
            
            [[ -n "${ssh_rule}" ]] && log_success "SSH (22) rule configured" || log_warn "SSH (22) rule missing"
            [[ -n "${http_rule}" ]] && log_success "HTTP (80) rule configured" || log_warn "HTTP (80) rule missing"
        else
            log_error "Security Group ${sg_id} not found"
            all_ok=false
        fi
    else
        log_warn "No security group in state"
    fi
    
    # Verify S3
    echo ""
    log_info "Checking S3 Bucket..."
    if state_has_resource "s3_bucket"; then
        local bucket_name
        bucket_name=$(state_get_resource_field "s3_bucket" "name")
        
        if aws_cmd s3api head-bucket --bucket "${bucket_name}" &>/dev/null; then
            log_success "S3 Bucket ${bucket_name} exists"
            
            # Check versioning
            local versioning
            versioning=$(aws_cmd s3api get-bucket-versioning \
                --bucket "${bucket_name}" \
                --query "Status" \
                --output text 2>/dev/null | tr -d '\r\n' || echo "None")
            
            [[ "${versioning}" == "Enabled" ]] && \
                log_success "Versioning is enabled" || \
                log_warn "Versioning status: ${versioning}"
            
            # Check if sample file exists
            if aws_cmd s3api head-object --bucket "${bucket_name}" --key "welcome.txt" &>/dev/null; then
                log_success "Sample file (welcome.txt) exists"
                local url="https://${bucket_name}.s3.${AWS_REGION}.amazonaws.com/welcome.txt"
                log_kv "Public URL" "${url}"
            else
                log_warn "Sample file (welcome.txt) not found"
            fi
        else
            log_error "S3 Bucket ${bucket_name} not found"
            all_ok=false
        fi
    else
        log_warn "No S3 bucket in state"
    fi
    
    # Final summary
    echo ""
    log_separator "="
    if [[ "${all_ok}" == "true" ]]; then
        log_success "All resources verified successfully!"
    else
        log_error "Some resources failed verification"
        exit 1
    fi
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_args() {
    local command=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            apply|destroy|plan|status|verify|help)
                command="$1"
                shift
                ;;
            --auto-approve)
                export AUTO_APPROVE="true"
                shift
                ;;
            --verbose|-v)
                export LOG_LEVEL="DEBUG"
                export VERBOSE="true"
                shift
                ;;
            --dry-run)
                export DRY_RUN="true"
                shift
                ;;
            --help|-h)
                command="help"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Default to help if no command given
    if [[ -z "${command}" ]]; then
        command="help"
    fi
    
    echo "${command}"
}

# ============================================================================
# Main
# ============================================================================

main() {
    local command
    command=$(parse_args "$@")
    
    case "${command}" in
        apply)
            cmd_apply
            ;;
        destroy)
            cmd_destroy
            ;;
        plan)
            cmd_plan
            ;;
        status)
            cmd_status
            ;;
        verify)
            cmd_verify
            ;;
        help)
            show_help
            ;;
        *)
            log_error "Unknown command: ${command}"
            show_help
            exit 1
            ;;
    esac
}

# Run main
main "$@"
