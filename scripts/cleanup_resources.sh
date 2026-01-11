#!/usr/bin/env bash
#
# cleanup_resources.sh - Clean up all AWS resources created by this project
#
# Implements a two-tier cleanup strategy:
#   1. State-driven cleanup (primary) - Uses state file to identify exact resources
#   2. Tag-based sweep (fallback) - Finds resources by Project tag
#
# Deletion Order (respects dependencies):
#   1. EC2 Instances (wait for termination)
#   2. Security Groups (must wait for ENIs to detach)
#   3. Key Pairs
#   4. S3 Buckets (empties all versions before deletion)
#
# Dependencies:
#   - AWS CLI v2
#   - jq (required for versioned S3 cleanup)
#   - lib/common.sh (provides logging, AWS helpers, state management)
#
# Environment Variables:
#   AWS_REGION      - Target AWS region (default: us-east-1)
#   AWS_PROFILE     - AWS CLI profile (default: default)
#   AUTO_APPROVE    - Skip confirmation prompts (default: false)
#   DRY_RUN         - Show what would be deleted without deleting (default: false)
#
# Exit Codes:
#   0 - Success (all resources cleaned up)
#   1 - Prerequisites failed
#   2 - Partial cleanup (some resources failed)
#   3 - User cancelled
#
# Example:
#   ./scripts/cleanup_resources.sh                    # Interactive mode
#   AUTO_APPROVE=true ./scripts/cleanup_resources.sh  # Non-interactive
#   DRY_RUN=true ./scripts/cleanup_resources.sh       # Preview mode
#
# Author: AutomationLab Project
# Version: 2.0.0
#

set -euo pipefail

# ===========================================================================
# Script Initialization
# ===========================================================================

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source the common library (loads config, logging, state, validation)
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"

# Source state management
# shellcheck source=../lib/state.sh
source "${PROJECT_ROOT}/lib/state.sh"

# Initialize script (validates prerequisites, sets up logging)
init_script

# ===========================================================================
# Configuration
# ===========================================================================

# Track cleanup status
CLEANUP_ERRORS=0

# ============================================================================
# S3 Bucket Cleanup Functions (handles versioned buckets!)
# ============================================================================

# Delete all object versions from a bucket
# This is REQUIRED before a versioned bucket can be deleted
delete_all_versions() {
    local bucket_name="$1"
    
    log_info "Deleting all object versions from bucket: ${bucket_name}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would delete all versions from ${bucket_name}"
        return 0
    fi
    
    # Method 1: Try using jq if available (more robust)
    if command -v jq &>/dev/null; then
        log_debug "Using jq for version deletion..."
        
        # Delete all object versions
        local versions
        versions=$(aws_cmd s3api list-object-versions \
            --bucket "${bucket_name}" \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null || echo '{"Objects": null}')
        
        if [[ $(echo "${versions}" | jq '.Objects | length // 0') -gt 0 ]]; then
            echo "${versions}" | aws_cmd s3api delete-objects \
                --bucket "${bucket_name}" \
                --delete "$(echo "${versions}" | jq -c '.')" >/dev/null 2>&1 || true
            log_info "Deleted object versions"
        fi
        
        # Delete all delete markers
        local markers
        markers=$(aws_cmd s3api list-object-versions \
            --bucket "${bucket_name}" \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null || echo '{"Objects": null}')
        
        if [[ $(echo "${markers}" | jq '.Objects | length // 0') -gt 0 ]]; then
            echo "${markers}" | aws_cmd s3api delete-objects \
                --bucket "${bucket_name}" \
                --delete "$(echo "${markers}" | jq -c '.')" >/dev/null 2>&1 || true
            log_info "Deleted delete markers"
        fi
    else
        # Method 2: Without jq - use AWS CLI text output and loop
        log_debug "Using AWS CLI text parsing for version deletion (jq not available)..."
        
        # Delete object versions one by one
        log_debug "Listing and deleting object versions..."
        local version_list
        version_list=$(aws_cmd s3api list-object-versions \
            --bucket "${bucket_name}" \
            --query 'Versions[*].[Key,VersionId]' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "${version_list}" ]]; then
            while IFS=$'\t' read -r key version_id; do
                if [[ -n "${key}" ]] && [[ -n "${version_id}" ]] && [[ "${key}" != "None" ]]; then
                    aws_cmd s3api delete-object \
                        --bucket "${bucket_name}" \
                        --key "${key}" \
                        --version-id "${version_id}" >/dev/null 2>&1 || true
                fi
            done <<< "${version_list}"
            log_info "Deleted object versions"
        fi
        
        # Delete delete markers one by one
        log_debug "Listing and deleting delete markers..."
        local marker_list
        marker_list=$(aws_cmd s3api list-object-versions \
            --bucket "${bucket_name}" \
            --query 'DeleteMarkers[*].[Key,VersionId]' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "${marker_list}" ]]; then
            while IFS=$'\t' read -r key version_id; do
                if [[ -n "${key}" ]] && [[ -n "${version_id}" ]] && [[ "${key}" != "None" ]]; then
                    aws_cmd s3api delete-object \
                        --bucket "${bucket_name}" \
                        --key "${key}" \
                        --version-id "${version_id}" >/dev/null 2>&1 || true
                fi
            done <<< "${marker_list}"
            log_info "Deleted delete markers"
        fi
    fi
    
    # Also use s3 rm for any remaining objects (belt and suspenders)
    log_debug "Running recursive delete for any remaining objects..."
    aws_cmd s3 rm "s3://${bucket_name}" --recursive >/dev/null 2>&1 || true
    
    log_success "Bucket emptied: ${bucket_name}"
}

# Delete an S3 bucket completely
delete_s3_bucket() {
    local bucket_name="$1"
    
    log_info "Deleting S3 bucket: ${bucket_name}"
    
    # Check if bucket exists
    if ! aws_cmd s3api head-bucket --bucket "${bucket_name}" &>/dev/null; then
        log_warn "Bucket does not exist or not accessible: ${bucket_name}"
        return 0
    fi
    
    if is_dry_run; then
        log_info "[DRY RUN] Would delete bucket: ${bucket_name}"
        return 0
    fi
    
    # Empty the bucket first (required for deletion)
    delete_all_versions "${bucket_name}" || {
        log_error "Failed to empty bucket: ${bucket_name}"
        return 1
    }
    
    # Delete the bucket
    aws_cmd s3api delete-bucket --bucket "${bucket_name}"
    
    log_success "Deleted bucket: ${bucket_name}"
}

# ============================================================================
# EC2 Cleanup Functions
# ============================================================================

# Terminate an EC2 instance and wait for termination
terminate_ec2_instance() {
    local instance_id="$1"
    
    log_info "Terminating EC2 instance: ${instance_id}"
    
    # Check if instance exists
    local state
    state=$(aws_cmd ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query "Reservations[0].Instances[0].State.Name" \
        --output text 2>/dev/null | tr -d '\r\n' || echo "not-found")
    
    if [[ "${state}" == "not-found" ]]; then
        log_warn "Instance does not exist: ${instance_id}"
        return 0
    fi
    
    if [[ "${state}" == "terminated" ]]; then
        log_info "Instance already terminated: ${instance_id}"
        return 0
    fi
    
    if is_dry_run; then
        log_info "[DRY RUN] Would terminate instance: ${instance_id}"
        return 0
    fi
    
    # Terminate the instance
    aws_cmd ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null
    log_info "Termination initiated, waiting for completion..."
    
    # Wait for termination
    aws_cmd ec2 wait instance-terminated --instance-ids "${instance_id}"
    
    log_success "Instance terminated: ${instance_id}"
}

# ============================================================================
# Security Group Cleanup Functions
# ============================================================================

# Delete a security group
delete_security_group() {
    local sg_id="$1"
    
    log_info "Deleting security group: ${sg_id}"
    
    # Check if SG exists
    if ! aws_cmd ec2 describe-security-groups --group-ids "${sg_id}" &>/dev/null; then
        log_warn "Security group does not exist: ${sg_id}"
        return 0
    fi
    
    if is_dry_run; then
        log_info "[DRY RUN] Would delete security group: ${sg_id}"
        return 0
    fi
    
    # Try to delete (may fail if still in use)
    local retry=0
    local max_retries=5
    
    while [[ ${retry} -lt ${max_retries} ]]; do
        if aws_cmd ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null; then
            log_success "Deleted security group: ${sg_id}"
            return 0
        fi
        
        retry=$((retry + 1))
        if [[ ${retry} -lt ${max_retries} ]]; then
            log_warn "Security group still in use, waiting 10s... (attempt ${retry}/${max_retries})"
            sleep 10
        fi
    done
    
    log_error "Failed to delete security group after ${max_retries} attempts"
    log_error "It may still be attached to network interfaces"
    return 1
}

# ============================================================================
# Key Pair Cleanup Functions
# ============================================================================

# Delete a key pair
delete_key_pair() {
    local key_name="$1"
    
    log_info "Deleting key pair: ${key_name}"
    
    # Check if key pair exists
    if ! aws_cmd ec2 describe-key-pairs --key-names "${key_name}" &>/dev/null; then
        log_warn "Key pair does not exist: ${key_name}"
        return 0
    fi
    
    if is_dry_run; then
        log_info "[DRY RUN] Would delete key pair: ${key_name}"
        return 0
    fi
    
    aws_cmd ec2 delete-key-pair --key-name "${key_name}"
    
    # Also remove local .pem file if it exists
    local pem_file="${PROJECT_ROOT}/${key_name}.pem"
    if [[ -f "${pem_file}" ]]; then
        rm -f "${pem_file}"
        log_debug "Removed local key file: ${pem_file}"
    fi
    
    log_success "Deleted key pair: ${key_name}"
}

# ============================================================================
# State-Driven Cleanup
# ============================================================================

# Clean up resources based on state file
cleanup_from_state() {
    log_info "Performing state-driven cleanup..."
    log_separator "-"
    
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_warn "No state file found at: ${STATE_FILE}"
        return 1
    fi
    
    # Verify environment matches state
    state_verify_environment || {
        log_error "State environment mismatch - refusing to cleanup"
        log_error "Use --force to override (dangerous!)"
        return 1
    }
    
    local resources_cleaned=0
    
    # Step 1: Terminate EC2 instances
    log_step 1 4 "Terminating EC2 instances"
    if state_has_resource "ec2_instance"; then
        local instance_id
        instance_id=$(state_get_resource_field "ec2_instance" "id")
        local status
        status=$(state_get_resource_field "ec2_instance" "status")
        
        if [[ "${status}" == "created" ]] && [[ -n "${instance_id}" ]]; then
            if terminate_ec2_instance "${instance_id}"; then
                state_destroy_resource "ec2_instance"
                resources_cleaned=$((resources_cleaned + 1))
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        fi
    else
        log_debug "No EC2 instance in state"
    fi
    
    # Step 2: Delete Security Groups
    log_step 2 4 "Deleting security groups"
    if state_has_resource "security_group"; then
        local sg_id
        sg_id=$(state_get_resource_field "security_group" "id")
        local status
        status=$(state_get_resource_field "security_group" "status")
        
        if [[ "${status}" == "created" ]] && [[ -n "${sg_id}" ]]; then
            if delete_security_group "${sg_id}"; then
                state_destroy_resource "security_group"
                resources_cleaned=$((resources_cleaned + 1))
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        fi
    else
        log_debug "No security group in state"
    fi
    
    # Step 3: Delete Key Pairs
    log_step 3 4 "Deleting key pairs"
    if state_has_resource "key_pair"; then
        local key_name
        key_name=$(state_get_resource_field "key_pair" "name")
        local status
        status=$(state_get_resource_field "key_pair" "status")
        
        if [[ "${status}" == "created" ]] && [[ -n "${key_name}" ]]; then
            if delete_key_pair "${key_name}"; then
                state_destroy_resource "key_pair"
                resources_cleaned=$((resources_cleaned + 1))
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        fi
    else
        log_debug "No key pair in state"
    fi
    
    # Step 4: Delete S3 Buckets
    log_step 4 4 "Deleting S3 buckets"
    if state_has_resource "s3_bucket"; then
        local bucket_name
        bucket_name=$(state_get_resource_field "s3_bucket" "name")
        local status
        status=$(state_get_resource_field "s3_bucket" "status")
        
        if [[ "${status}" == "created" ]] && [[ -n "${bucket_name}" ]]; then
            if delete_s3_bucket "${bucket_name}"; then
                state_destroy_resource "s3_bucket"
                resources_cleaned=$((resources_cleaned + 1))
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        fi
    else
        log_debug "No S3 bucket in state"
    fi
    
    log_separator "-"
    log_info "State-driven cleanup completed: ${resources_cleaned} resources cleaned"
    
    return 0
}

# ============================================================================
# Tag-Based Sweep (Fallback)
# ============================================================================

# Clean up resources by tag (fallback when state is missing)
cleanup_by_tags() {
    log_warn "Performing tag-based sweep..."
    log_warn "This will delete ALL resources tagged with ${TAG_KEY}=${PROJECT_TAG}"
    log_separator "-"
    
    # EC2 Instances
    log_step 1 4 "Finding EC2 instances by tag"
    local instances
    instances=$(aws_cmd ec2 describe-instances \
        --filters "Name=tag:${TAG_KEY},Values=${PROJECT_TAG}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${instances}" ]]; then
        for instance_id in ${instances}; do
            if terminate_ec2_instance "${instance_id}"; then
                # Update state if this instance matches state
                local state_instance_id
                state_instance_id=$(state_get_resource_field "ec2_instance" "id" 2>/dev/null || echo "")
                if [[ "${instance_id}" == "${state_instance_id}" ]]; then
                    state_destroy_resource "ec2_instance"
                fi
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        done
    else
        log_debug "No tagged EC2 instances found"
    fi
    
    # Security Groups
    log_step 2 4 "Finding security groups by tag"
    local security_groups
    security_groups=$(aws_cmd ec2 describe-security-groups \
        --filters "Name=tag:${TAG_KEY},Values=${PROJECT_TAG}" \
        --query "SecurityGroups[].GroupId" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${security_groups}" ]]; then
        for sg_id in ${security_groups}; do
            if delete_security_group "${sg_id}"; then
                # Update state if this SG matches state
                local state_sg_id
                state_sg_id=$(state_get_resource_field "security_group" "id" 2>/dev/null || echo "")
                if [[ "${sg_id}" == "${state_sg_id}" ]]; then
                    state_destroy_resource "security_group"
                fi
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        done
    else
        log_debug "No tagged security groups found"
    fi
    
    # Key Pairs (by name prefix since they can't be tagged)
    log_step 3 4 "Finding key pairs by prefix"
    local key_pairs
    key_pairs=$(aws_cmd ec2 describe-key-pairs \
        --query "KeyPairs[?starts_with(KeyName, '${NAME_PREFIX}')].KeyName" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${key_pairs}" ]]; then
        for key_name in ${key_pairs}; do
            if delete_key_pair "${key_name}"; then
                # Update state if this key matches state
                local state_key_name
                state_key_name=$(state_get_resource_field "key_pair" "name" 2>/dev/null || echo "")
                if [[ "${key_name}" == "${state_key_name}" ]]; then
                    state_destroy_resource "key_pair"
                fi
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        done
    else
        log_debug "No matching key pairs found"
    fi
    
    # S3 Buckets (by name prefix since listing all bucket tags is slow)
    log_step 4 4 "Finding S3 buckets by prefix"
    local buckets
    buckets=$(aws_cmd s3api list-buckets \
        --query "Buckets[?starts_with(Name, '${NAME_PREFIX}')].Name" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${buckets}" ]]; then
        for bucket_name in ${buckets}; do
            if delete_s3_bucket "${bucket_name}"; then
                # Update state if this bucket matches state
                local state_bucket
                state_bucket=$(state_get_resource_field "s3_bucket" "name" 2>/dev/null || echo "")
                if [[ "${bucket_name}" == "${state_bucket}" ]]; then
                    state_destroy_resource "s3_bucket"
                fi
            else
                CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
            fi
        done
    else
        log_debug "No matching S3 buckets found"
    fi
    
    log_separator "-"
    log_info "Tag-based sweep completed"
}

# ============================================================================
# Plan Mode (Preview)
# ============================================================================

# Show what would be deleted without actually deleting
show_cleanup_plan() {
    log_info "Cleanup Plan (Preview Mode)"
    log_separator "="
    
    echo ""
    echo "The following resources would be deleted:"
    echo ""
    
    local resources_found=0
    
    # From state file
    if [[ -f "${STATE_FILE}" ]]; then
        echo "=== Resources from State File ==="
        
        if state_has_resource "ec2_instance"; then
            local id=$(state_get_resource_field "ec2_instance" "id")
            echo "  EC2 Instance: ${id}"
            resources_found=$((resources_found + 1))
        fi
        
        if state_has_resource "security_group"; then
            local id=$(state_get_resource_field "security_group" "id")
            echo "  Security Group: ${id}"
            resources_found=$((resources_found + 1))
        fi
        
        if state_has_resource "key_pair"; then
            local name=$(state_get_resource_field "key_pair" "name")
            echo "  Key Pair: ${name}"
            resources_found=$((resources_found + 1))
        fi
        
        if state_has_resource "s3_bucket"; then
            local name=$(state_get_resource_field "s3_bucket" "name")
            echo "  S3 Bucket: ${name}"
            resources_found=$((resources_found + 1))
        fi
        
        echo ""
    fi
    
    # From AWS (tag-based)
    echo "=== Resources Found by Tag (${TAG_KEY}=${PROJECT_TAG}) ==="
    
    local instances=$(aws_cmd ec2 describe-instances \
        --filters "Name=tag:${TAG_KEY},Values=${PROJECT_TAG}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name'].Value|[0]]" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${instances}" ]]; then
        echo "  EC2 Instances:"
        echo "${instances}" | while read -r id name; do
            echo "    - ${id} (${name:-unnamed})"
        done
    fi
    
    local sgs=$(aws_cmd ec2 describe-security-groups \
        --filters "Name=tag:${TAG_KEY},Values=${PROJECT_TAG}" \
        --query "SecurityGroups[].[GroupId,GroupName]" \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${sgs}" ]]; then
        echo "  Security Groups:"
        echo "${sgs}" | while read -r id name; do
            echo "    - ${id} (${name})"
        done
    fi
    
    echo ""
    log_separator "="
    
    if [[ ${resources_found} -eq 0 ]]; then
        log_info "No resources found to clean up"
    else
        log_warn "Run without DRY_RUN=true to delete these resources"
    fi
}

# ============================================================================
# Main Logic
# ============================================================================

main() {
    log_info "Starting resource cleanup..."
    log_kv "Region" "${AWS_REGION}"
    log_kv "Profile" "${AWS_PROFILE}"
    log_kv "Project Tag" "${TAG_KEY}=${PROJECT_TAG}"
    log_separator "="
    
    # Initialize state
    state_init
    
    # Show plan in dry run mode
    if is_dry_run; then
        show_cleanup_plan
        return 0
    fi
    
    # Confirmation prompt
    if ! confirm "This will DELETE all AutomationLab resources. Continue?"; then
        log_info "Cleanup cancelled by user"
        exit 3
    fi
    
    echo ""
    log_warn "Starting cleanup in 3 seconds... (Ctrl+C to cancel)"
    sleep 3
    
    # Try state-driven cleanup first
    if [[ -f "${STATE_FILE}" ]] && state_has_resources; then
        cleanup_from_state
    else
        log_warn "No state file or no resources in state"
        log_warn "Falling back to tag-based cleanup"
        cleanup_by_tags
    fi
    
    # Show final status
    log_separator "="
    if [[ ${CLEANUP_ERRORS} -eq 0 ]]; then
        log_success "Cleanup completed successfully!"
        
        # Show final state
        state_show
    else
        log_error "Cleanup completed with ${CLEANUP_ERRORS} errors"
        log_error "Some resources may not have been deleted"
        exit 2
    fi
}

# Run main function
main "$@"

