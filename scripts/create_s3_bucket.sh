#!/usr/bin/env bash
#
# create_s3_bucket.sh - Create and configure an AWS S3 Bucket
#
# Creates a uniquely named S3 bucket with:
#   - Versioning enabled
#   - Simple bucket policy (public read - for demo purposes only!)
#   - Sample file upload (welcome.txt)
#   - Proper project tagging
#
# Dependencies:
#   - AWS CLI v2
#   - lib/common.sh (provides logging, AWS helpers, state management)
#
# Environment Variables:
#   AWS_REGION      - Target AWS region (default: us-east-1)
#   AWS_PROFILE     - AWS CLI profile (default: default)
#   BUCKET_PREFIX   - Prefix for bucket name (default: automationlab-bucket)
#   BUCKET_NAME     - Full bucket name (overrides prefix+timestamp)
#
# Outputs:
#   - Creates S3 bucket with versioning
#   - Uploads welcome.txt sample file
#   - Updates state file with bucket details
#   - Prints bucket name and URL
#
# Exit Codes:
#   0 - Success
#   1 - Prerequisites failed
#   2 - AWS API error
#   3 - State file error
#
# SECURITY WARNING:
#   This script applies a PUBLIC READ policy for demonstration purposes.
#   DO NOT use public buckets in production without proper security review!
#
# Example:
#   ./scripts/create_s3_bucket.sh
#   BUCKET_PREFIX=my-project ./scripts/create_s3_bucket.sh
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

# S3 settings from config.env (via common.sh)
S3_BUCKET_PREFIX="${BUCKET_PREFIX}"
S3_SAMPLE_FILE_NAME="${S3_SAMPLE_FILE}"
S3_SAMPLE_CONTENT="${S3_SAMPLE_CONTENT}"

# Generate unique bucket name with timestamp
TIMESTAMP=$(date +%s)
S3_BUCKET_NAME="${BUCKET_NAME:-${S3_BUCKET_PREFIX}-${TIMESTAMP}}"

# Temporary file for sample content
TEMP_SAMPLE_FILE="${PROJECT_ROOT}/${S3_SAMPLE_FILE_NAME}"

# ============================================================================
# Functions
# ============================================================================

# Validate and sanitize bucket name
prepare_bucket_name() {
    local name="$1"
    
    # Sanitize if needed
    local sanitized
    sanitized=$(sanitize_bucket_name "${name}")
    
    if [[ "${name}" != "${sanitized}" ]]; then
        log_warn "Bucket name was sanitized: '${name}' Ã¢â€ â€™ '${sanitized}'"
        name="${sanitized}"
    fi
    
    # Validate
    if ! validate_bucket_name "${name}"; then
        log_error "Invalid bucket name even after sanitization"
        return 1
    fi
    
    echo "${name}"
}

# Create S3 bucket
create_bucket() {
    local bucket_name="$1"
    local region="$2"
    
    log_info "Creating S3 bucket: ${bucket_name}"
    log_kv "Region" "${region}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would create bucket: ${bucket_name}"
        return 0
    fi
    
    # Special handling for us-east-1 (no LocationConstraint needed)
    if [[ "${region}" == "us-east-1" ]]; then
        aws_cmd s3api create-bucket \
            --bucket "${bucket_name}" \
            --output text >/dev/null
    else
        aws_cmd s3api create-bucket \
            --bucket "${bucket_name}" \
            --create-bucket-configuration "LocationConstraint=${region}" \
            --output text >/dev/null
    fi
    
    log_success "Bucket created: ${bucket_name}"
}

# Enable versioning on bucket
enable_versioning() {
    local bucket_name="$1"
    
    log_info "Enabling versioning on bucket: ${bucket_name}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would enable versioning"
        return 0
    fi
    
    aws_cmd s3api put-bucket-versioning \
        --bucket "${bucket_name}" \
        --versioning-configuration Status=Enabled
    
    log_success "Versioning enabled"
}

# Apply bucket policy (public read - for demo only!)
apply_bucket_policy() {
    local bucket_name="$1"
    
    log_warn "Applying PUBLIC READ policy to bucket (for demonstration only!)"
    log_warn "DO NOT use this in production without security review!"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would apply public read policy"
        return 0
    fi
    
    # Construct policy JSON
    local policy
    read -r -d '' policy << EOF || true
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::${bucket_name}/*"]
    }
  ]
}
EOF

    # First, we need to disable block public access to apply public policy
    log_debug "Disabling block public access settings..."
    aws_cmd s3api put-public-access-block \
        --bucket "${bucket_name}" \
        --public-access-block-configuration \
        "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" || {
            log_warn "Could not disable block public access - policy may fail"
        }
    
    # Small delay to allow settings to propagate
    sleep 2
    
    # Apply the policy
    aws_cmd s3api put-bucket-policy \
        --bucket "${bucket_name}" \
        --policy "${policy}"
    
    log_success "Bucket policy applied (public read)"
}

# Apply tags to bucket
tag_bucket() {
    local bucket_name="$1"
    
    log_debug "Applying tags: ${TAG_KEY}=${PROJECT_TAG}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would apply tags"
        return 0
    fi
    
    aws_cmd s3api put-bucket-tagging \
        --bucket "${bucket_name}" \
        --tagging "TagSet=[{Key=${TAG_KEY},Value=${PROJECT_TAG}}]"
    
    log_success "Tags applied to bucket"
}

# Upload sample file to bucket
upload_sample_file() {
    local bucket_name="$1"
    local local_file="$2"
    local s3_key="$3"
    
    log_info "Uploading sample file: ${s3_key}"
    
    if is_dry_run; then
        log_info "[DRY RUN] Would upload: ${local_file} Ã¢â€ â€™ s3://${bucket_name}/${s3_key}"
        return 0
    fi
    
    # Create the sample file
    echo "${S3_SAMPLE_CONTENT}" > "${local_file}"
    log_debug "Created local file: ${local_file}"
    
    # Upload to S3
    aws_cmd s3 cp "${local_file}" "s3://${bucket_name}/${s3_key}"
    
    log_success "File uploaded: s3://${bucket_name}/${s3_key}"
    
    # Clean up local file
    rm -f "${local_file}"
}

# Display bucket information
display_bucket_info() {
    local bucket_name="$1"
    
    log_info "Retrieving bucket information..."
    
    echo ""
    echo "=== S3 Bucket Info ==="
    
    echo "Location:"
    aws_cmd s3api get-bucket-location --bucket "${bucket_name}" --output json
    
    echo ""
    echo "Versioning:"
    aws_cmd s3api get-bucket-versioning --bucket "${bucket_name}" --output json
    
    echo ""
    echo "Tags:"
    aws_cmd s3api get-bucket-tagging --bucket "${bucket_name}" --output json 2>/dev/null || echo "  (no tags)"
    
    echo "======================="
    echo ""
}

# ============================================================================
# Main Logic
# ============================================================================

main() {
    log_info "Starting S3 bucket creation..."
    log_separator "-"
    
    # Initialize state
    state_init
    
    # Check if we already have a bucket in state
    if state_has_resource "s3_bucket"; then
        local existing_name
        existing_name=$(state_get_resource_field "s3_bucket" "name")
        local existing_status
        existing_status=$(state_get_resource_field "s3_bucket" "status")
        
        if [[ "${existing_status}" == "created" ]] && [[ -n "${existing_name}" ]]; then
            log_info "S3 bucket already exists in state: ${existing_name}"
            
            # Verify it still exists in AWS
            if aws_cmd s3api head-bucket --bucket "${existing_name}" &>/dev/null; then
                log_success "Verified bucket exists in AWS"
                display_bucket_info "${existing_name}"
                
                print_summary "Existing S3 Bucket" \
                    "Bucket Name:${existing_name}" \
                    "URL:https://${existing_name}.s3.${AWS_REGION}.amazonaws.com" \
                    "Sample File:s3://${existing_name}/${S3_SAMPLE_FILE_NAME}"
                
                echo "BUCKET_NAME=${existing_name}"
                return 0
            else
                log_warn "Bucket in state no longer exists in AWS, will recreate"
            fi
        fi
    fi
    
    # Prepare and validate bucket name
    local bucket_name
    bucket_name=$(prepare_bucket_name "${S3_BUCKET_NAME}") || exit 1
    log_info "Bucket name: ${bucket_name}"
    
    # Check if bucket already exists (globally unique namespace)
    if aws_cmd s3api head-bucket --bucket "${bucket_name}" &>/dev/null 2>&1; then
        log_warn "Bucket '${bucket_name}' already exists"
        log_warn "S3 bucket names are globally unique - this might be someone else's bucket"
        
        # Check if we own it by trying to get location
        if aws_cmd s3api get-bucket-location --bucket "${bucket_name}" &>/dev/null; then
            log_info "We have access to this bucket, will reuse it"
        else
            log_error "Cannot access bucket - it belongs to another AWS account"
            log_error "Try using a different BUCKET_PREFIX"
            exit 2
        fi
    else
        # Create the bucket
        create_bucket "${bucket_name}" "${AWS_REGION}" || exit 2
    fi
    
    # Enable versioning
    enable_versioning "${bucket_name}" || log_warn "Failed to enable versioning"
    
    # Apply bucket policy (public read for demo)
    apply_bucket_policy "${bucket_name}" || log_warn "Failed to apply bucket policy"
    
    # Apply tags
    tag_bucket "${bucket_name}" || log_warn "Failed to apply tags"
    
    # Upload sample file
    upload_sample_file "${bucket_name}" "${TEMP_SAMPLE_FILE}" "${S3_SAMPLE_FILE_NAME}" || \
        log_warn "Failed to upload sample file"
    
    # Update state file
    if ! is_dry_run; then
        local s3_json
        s3_json=$(state_s3_json "${bucket_name}" "${AWS_REGION}")
        state_set_resource "s3_bucket" "${s3_json}"
        log_debug "State updated with S3 bucket info"
    fi
    
    # Display bucket info
    display_bucket_info "${bucket_name}"
    
    # Calculate public URL for the sample file
    local sample_url="https://${bucket_name}.s3.${AWS_REGION}.amazonaws.com/${S3_SAMPLE_FILE_NAME}"
    
    # Print summary
    print_summary "S3 Bucket Created" \
        "Bucket Name:${bucket_name}" \
        "Region:${AWS_REGION}" \
        "Versioning:Enabled" \
        "Policy:Public Read (DEMO ONLY)" \
        "Sample File:${S3_SAMPLE_FILE_NAME}" \
        "Sample URL:${sample_url}" \
        "Tag:${TAG_KEY}=${PROJECT_TAG}"
    
    log_success "S3 bucket provisioning completed successfully"
    
    # Output for orchestration (machine-readable)
    echo "BUCKET_NAME=${bucket_name}"
    echo "BUCKET_URL=https://${bucket_name}.s3.${AWS_REGION}.amazonaws.com"
}

# Run main function
main "$@"


