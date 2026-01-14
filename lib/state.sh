#!/usr/bin/env bash
#
# state.sh - Terraform-like State File Management
#
# Provides reliable state tracking for created AWS resources.
# Enables accurate cleanup and prevents resource orphaning.
#
# Features:
#   - JSON-based state file (easy to inspect and parse)
#   - Atomic writes (prevents corruption)
#   - Lock file support (prevents concurrent access)
#   - Per-workspace state files
#   - Resource status tracking (created, failed, destroyed)
#
# State File Location:
#   .state/<workspace>.json (default: .state/default.json)
#
# Usage:
#   source lib/state.sh
#   state_init
#   state_set_resource "ec2_instance" "i-1234567890abcdef0" "created"
#   instance_id=$(state_get_resource "ec2_instance" "id")
#
# Author: AutomationLab Project
# Version: 1.0.0
#

# Prevent multiple sourcing
[[ -n "${_STATE_SH_LOADED:-}" ]] && return 0
readonly _STATE_SH_LOADED=1

# ============================================================================
# Dependencies
# ============================================================================

# Ensure logging is available (may already be loaded via common.sh)
if ! declare -f log_info &>/dev/null; then
    _STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_STATE_LIB_DIR}/logging.sh"
fi

# ============================================================================
# State Configuration
# ============================================================================

# State directory and file (can be overridden via config.env)
STATE_DIR="${STATE_DIR:-.state}"
WORKSPACE="${WORKSPACE:-default}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/${WORKSPACE}.json}"
STATE_LOCK_FILE="${STATE_LOCK_FILE:-${STATE_DIR}/${WORKSPACE}.lock}"

# Lock timeout in seconds
STATE_LOCK_TIMEOUT="${STATE_LOCK_TIMEOUT:-30}"

# Schema version for future migrations
STATE_SCHEMA_VERSION="1.0"

# ============================================================================
# Lock Management
# ============================================================================

# Acquire lock on state file
# Returns: 0 if lock acquired, 1 if failed
state_lock() {
    local lock_file="${STATE_LOCK_FILE}"
    local timeout="${STATE_LOCK_TIMEOUT}"
    local waited=0
    
    log_debug "Acquiring state lock: ${lock_file}"
    
    # Create lock directory if needed
    mkdir -p "$(dirname "${lock_file}")" 2>/dev/null || true
    
    while [[ -f "${lock_file}" ]]; do
        # Check if lock is stale (older than timeout)
        if [[ -f "${lock_file}" ]]; then
            local lock_age
            # Get lock file age in seconds
            if [[ "$(uname)" == "Darwin" ]]; then
                lock_age=$(( $(date +%s) - $(stat -f %m "${lock_file}") ))
            else
                lock_age=$(( $(date +%s) - $(stat -c %Y "${lock_file}" 2>/dev/null || echo 0) ))
            fi
            
            if [[ ${lock_age} -gt ${timeout} ]]; then
                log_warn "Stale lock detected (${lock_age}s old), removing..."
                rm -f "${lock_file}"
                break
            fi
        fi
        
        if [[ ${waited} -ge ${timeout} ]]; then
            log_error "Failed to acquire state lock after ${timeout}s"
            log_error "Another operation may be in progress"
            log_error "If not, remove ${lock_file} manually"
            return 1
        fi
        
        log_debug "Waiting for state lock... (${waited}s)"
        sleep 1
        waited=$((waited + 1))
    done
    
    # Create lock file with PID for debugging
    echo "$$" > "${lock_file}"
    log_debug "State lock acquired"
    return 0
}

# Release state lock
state_unlock() {
    local lock_file="${STATE_LOCK_FILE}"
    
    if [[ -f "${lock_file}" ]]; then
        rm -f "${lock_file}"
        log_debug "State lock released"
    fi
}

# ============================================================================
# State File Operations
# ============================================================================

# Initialize state file if it doesn't exist
state_init() {
    log_debug "Initializing state for workspace: ${WORKSPACE}"
    
    # Ensure state directory exists
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    
    # Create initial state file if it doesn't exist
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_info "Creating new state file: ${STATE_FILE}"
        
        local timestamp
        timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
        
        # Get AWS account ID if available
        local account_id="${AWS_ACCOUNT_ID:-unknown}"
        
        # Create initial state structure
        cat > "${STATE_FILE}" << EOF
{
  "schema_version": "${STATE_SCHEMA_VERSION}",
  "metadata": {
    "workspace": "${WORKSPACE}",
    "created_at": "${timestamp}",
    "updated_at": "${timestamp}",
    "aws_account_id": "${account_id}",
    "aws_region": "${AWS_REGION:-us-east-1}",
    "aws_profile": "${AWS_PROFILE:-default}"
  },
  "config": {
    "project_tag": "${PROJECT_TAG:-AutomationLab}",
    "name_prefix": "${NAME_PREFIX:-automationlab}"
  },
  "resources": {
    "key_pair": null,
    "security_group": null,
    "ec2_instance": null,
    "s3_bucket": null
  }
}
EOF
        log_success "State file initialized"
    else
        log_debug "State file already exists: ${STATE_FILE}"
    fi
    
    return 0
}

# Read the entire state file
state_read() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_debug "State file does not exist"
        echo "{}"
        return 1
    fi
    
    cat "${STATE_FILE}"
}

# Write to state file with atomic operation
# Writes to temp file first, then moves to prevent corruption
_state_write_atomic() {
    local content="$1"
    local temp_file="${STATE_FILE}.tmp.$$"
    
    # Write to temp file
    echo "${content}" > "${temp_file}"
    
    # Atomic move
    mv "${temp_file}" "${STATE_FILE}"
    
    log_debug "State file updated atomically"
}

# Update a specific resource in the state
# Usage: state_set_resource "ec2_instance" '{"id": "i-xxx", "status": "created"}'
state_set_resource() {
    local resource_type="$1"
    local resource_data="$2"
    
    state_lock || return 1
    
    # Add timestamp to resource data
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    
    if command -v jq &>/dev/null; then
        # Use jq for proper JSON manipulation
        local current_state
        current_state=$(state_read)
        
        # Add/update resource and update timestamp
        local new_state
        new_state=$(echo "${current_state}" | jq \
            --arg type "${resource_type}" \
            --argjson data "${resource_data}" \
            --arg ts "${timestamp}" \
            '.resources[$type] = $data | .metadata.updated_at = $ts')
        
        _state_write_atomic "${new_state}"
    else
        # Fallback without jq - use sed/awk for basic JSON manipulation
        log_debug "jq not available - using text-based state update"
        
        if [[ -f "${STATE_FILE}" ]]; then
            local temp_file="${STATE_FILE}.tmp.$$"
            
            # Read current state
            local current_content
            current_content=$(cat "${STATE_FILE}")
            
            # Check if resources section is empty: "resources": {}
            if echo "${current_content}" | grep -q '"resources": *{}'; then
                # Empty resources - insert new resource
                # Replace "resources": {} with "resources": { "type": data }
                local insert_data
                insert_data=$(printf '  "resources": {\n    "%s": %s\n  }' "${resource_type}" "${resource_data}")
                
                # Use awk to replace the empty resources block
                awk -v new_block="${insert_data}" '
                    /"resources": *\{\}/ { 
                        print new_block
                        next 
                    }
                    { print }
                ' "${STATE_FILE}" > "${temp_file}"
                
            elif echo "${current_content}" | grep -q "\"${resource_type}\":"; then
                # Resource exists - update it
                # This is complex without jq, so we rebuild the resources section
                log_debug "Updating existing resource ${resource_type}"
                
                # For simplicity, read existing resources and rebuild
                awk -v type="${resource_type}" -v data="${resource_data}" '
                    BEGIN { in_resources = 0; done = 0 }
                    /"resources": *\{/ { 
                        in_resources = 1 
                        print
                        next
                    }
                    in_resources && /^  *\}/ && !done {
                        # End of resources block - we handled it
                        in_resources = 0
                        print
                        next
                    }
                    in_resources && match($0, "\"" type "\":") {
                        # Found our resource type - replace the line
                        # Handle multi-line by skipping until we close the brace
                        printf "    \"%s\": %s", type, data
                        # Check if this line has closing brace
                        if (match($0, /\}[,]? *$/)) {
                            if (match($0, /,$/)) print ","
                            else print ""
                        } else {
                            # Multi-line object - skip until closing
                            brace = 1
                            while (brace > 0 && (getline line) > 0) {
                                brace += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
                            }
                            if (match(line, /,$/)) print ","
                            else print ""
                        }
                        done = 1
                        next
                    }
                    { print }
                ' "${STATE_FILE}" > "${temp_file}"
            else
                # Resource doesn't exist - add it to resources block
                # Find "resources": { and add new entry
                awk -v type="${resource_type}" -v data="${resource_data}" '
                    /"resources": *\{/ { 
                        print
                        printf "    \"%s\": %s,\n", type, data
                        next
                    }
                    { print }
                ' "${STATE_FILE}" > "${temp_file}"
            fi
            
            # Move temp file to state file
            mv "${temp_file}" "${STATE_FILE}"
            
            # Update timestamp
            sed -i "s/\"updated_at\": *\"[^\"]*\"/\"updated_at\": \"${timestamp}\"/" "${STATE_FILE}"
            
            log_debug "State updated via text parsing for ${resource_type}"
        else
            log_error "State file not found for update"
            state_unlock
            return 1
        fi
    fi
    
    state_unlock
    log_debug "Updated state for ${resource_type}"
    return 0
}

# Get a resource from state
# Usage: state_get_resource "ec2_instance"
# Returns: JSON object for the resource or "null"
state_get_resource() {
    local resource_type="$1"
    
    if [[ ! -f "${STATE_FILE}" ]]; then
        echo "null"
        return 1
    fi
    
    if command -v jq &>/dev/null; then
        jq -r ".resources.${resource_type} // null" "${STATE_FILE}"
    else
        # Basic fallback - check if resource is null or has content
        local content
        content=$(cat "${STATE_FILE}")
        
        # Check if the resource is null
        if echo "${content}" | grep -q "\"${resource_type}\": *null"; then
            echo "null"
            return 1
        fi
        
        # Try to extract the resource JSON block
        # This is a simplified extraction - may not work for complex nested JSON
        local in_resource=false
        local brace_count=0
        local result=""
        
        while IFS= read -r line; do
            if [[ "${in_resource}" == "false" ]] && echo "${line}" | grep -q "\"${resource_type}\":"; then
                in_resource=true
                # Extract everything after the colon
                result=$(echo "${line}" | sed "s/.*\"${resource_type}\": *//")
                # Count opening braces
                brace_count=$(echo "${result}" | tr -cd '{' | wc -c)
                brace_count=$((brace_count - $(echo "${result}" | tr -cd '}' | wc -c)))
            elif [[ "${in_resource}" == "true" ]]; then
                result="${result}${line}"
                brace_count=$((brace_count + $(echo "${line}" | tr -cd '{' | wc -c)))
                brace_count=$((brace_count - $(echo "${line}" | tr -cd '}' | wc -c)))
                if [[ ${brace_count} -le 0 ]]; then
                    break
                fi
            fi
        done < "${STATE_FILE}"
        
        if [[ -n "${result}" ]]; then
            # Clean up trailing comma if present
            echo "${result}" | sed 's/,$//'
        else
            echo "null"
        fi
    fi
}

# Get a specific field from a resource
# Usage: state_get_resource_field "ec2_instance" "id"
# Returns: The field value or empty string
state_get_resource_field() {
    local resource_type="$1"
    local field="$2"
    
    local resource
    resource=$(state_get_resource "${resource_type}")
    
    if [[ "${resource}" == "null" ]] || [[ -z "${resource}" ]]; then
        echo ""
        return 1
    fi
    
    if command -v jq &>/dev/null; then
        echo "${resource}" | jq -r ".${field} // empty"
    else
        # Try to extract the field value - handles both "field": "value" and "field": value
        local value
        value=$(echo "${resource}" | grep -o "\"${field}\": *\"[^\"]*\"" | sed 's/.*: *"//' | sed 's/"$//')
        if [[ -z "${value}" ]]; then
            # Try without quotes (for numbers, booleans)
            value=$(echo "${resource}" | grep -o "\"${field}\": *[^,}]*" | sed "s/.*: *//" | tr -d ' ')
        fi
        echo "${value}"
    fi
}

# Check if a resource exists in state
# Usage: state_has_resource "ec2_instance"
# Returns: 0 if exists, 1 if not
state_has_resource() {
    local resource_type="$1"
    local resource
    resource=$(state_get_resource "${resource_type}")
    
    [[ "${resource}" != "null" ]] && [[ -n "${resource}" ]]
}

# Mark a resource as destroyed
state_destroy_resource() {
    local resource_type="$1"
    
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    
    # Get current resource data and update status
    local current
    current=$(state_get_resource "${resource_type}")
    
    if [[ "${current}" == "null" ]]; then
        log_debug "Resource ${resource_type} not in state"
        return 0
    fi
    
    if command -v jq &>/dev/null; then
        local updated
        updated=$(echo "${current}" | jq \
            --arg ts "${timestamp}" \
            '. + {status: "destroyed", destroyed_at: $ts}')
        state_set_resource "${resource_type}" "${updated}"
    else
        # Fallback without jq - use sed to update status in file
        if [[ -f "${STATE_FILE}" ]]; then
            # Replace "status": "created" with "status": "destroyed" for this resource section
            # This is a simplified approach
            sed -i "s/\"${resource_type}\": *{[^}]*\"status\": *\"created\"/&/; s/\"status\": *\"created\"/\"status\": \"destroyed\", \"destroyed_at\": \"${timestamp}\"/" "${STATE_FILE}" 2>/dev/null || true
            log_debug "Updated ${resource_type} status to destroyed (via sed)"
        fi
    fi
    
    log_debug "Marked ${resource_type} as destroyed"
}

# Clear a resource from state (remove entirely)
state_clear_resource() {
    local resource_type="$1"
    state_set_resource "${resource_type}" "null"
    log_debug "Cleared ${resource_type} from state"
}

# ============================================================================
# State Queries
# ============================================================================

# Get all resources with a specific status
# Usage: state_get_by_status "created"
state_get_by_status() {
    local status="$1"
    
    if command -v jq &>/dev/null; then
        jq -r ".resources | to_entries | .[] | select(.value.status == \"${status}\") | .key" "${STATE_FILE}" 2>/dev/null
    else
        log_warn "jq required for state_get_by_status"
        return 1
    fi
}

# Check if state has any created resources
state_has_resources() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        return 1
    fi
    
    if command -v jq &>/dev/null; then
        local created
        created=$(state_get_by_status "created" 2>/dev/null | wc -l)
        [[ ${created} -gt 0 ]]
    else
        # Fallback without jq - check if any resource has "status": "created"
        grep -q '"status": *"created"' "${STATE_FILE}" 2>/dev/null
    fi
}

# Get state metadata
state_get_metadata() {
    local field="$1"
    
    if command -v jq &>/dev/null; then
        jq -r ".metadata.${field} // empty" "${STATE_FILE}" 2>/dev/null
    else
        grep -o "\"${field}\":\"[^\"]*\"" "${STATE_FILE}" 2>/dev/null | head -1 | cut -d'"' -f4
    fi
}

# Verify state matches current AWS environment
state_verify_environment() {
    local state_region
    local state_account
    
    state_region=$(state_get_metadata "aws_region")
    state_account=$(state_get_metadata "aws_account_id")
    
    if [[ -n "${state_region}" ]] && [[ "${state_region}" != "${AWS_REGION}" ]]; then
        log_error "State region mismatch!"
        log_error "  State: ${state_region}"
        log_error "  Current: ${AWS_REGION}"
        return 1
    fi
    
    if [[ -n "${state_account}" ]] && [[ "${state_account}" != "unknown" ]]; then
        if [[ -n "${AWS_ACCOUNT_ID:-}" ]] && [[ "${state_account}" != "${AWS_ACCOUNT_ID}" ]]; then
            log_error "State account mismatch!"
            log_error "  State: ${state_account}"
            log_error "  Current: ${AWS_ACCOUNT_ID}"
            return 1
        fi
    fi
    
    log_debug "State environment verified"
    return 0
}

# ============================================================================
# State Display
# ============================================================================

# Print current state in human-readable format
state_show() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_info "No state file found at ${STATE_FILE}"
        return 0
    fi
    
    echo ""
    echo "========================================"
    echo " State: ${WORKSPACE}"
    echo "========================================"
    echo " File: ${STATE_FILE}"
    echo " Region: $(state_get_metadata "aws_region")"
    echo " Account: $(state_get_metadata "aws_account_id")"
    echo " Created: $(state_get_metadata "created_at")"
    echo " Updated: $(state_get_metadata "updated_at")"
    echo "----------------------------------------"
    echo " Resources:"
    
    local resource_types=("key_pair" "security_group" "ec2_instance" "s3_bucket")
    for rt in "${resource_types[@]}"; do
        local res
        res=$(state_get_resource "${rt}")
        if [[ "${res}" != "null" ]] && [[ -n "${res}" ]]; then
            local status id
            if command -v jq &>/dev/null; then
                status=$(echo "${res}" | jq -r '.status // "unknown"')
                id=$(echo "${res}" | jq -r '.id // .name // "?"')
            else
                status="present"
                id="(jq required for details)"
            fi
            printf "   %-18s %s (%s)\n" "${rt}:" "${id}" "${status}"
        else
            printf "   %-18s %s\n" "${rt}:" "-"
        fi
    done
    
    echo "========================================"
    echo ""
}

# ============================================================================
# Helper Functions for Resource Creation
# ============================================================================

# Create JSON for a key pair resource
state_key_pair_json() {
    local name="$1"
    local pem_file="${2:-}"
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    
    cat << EOF
{
  "name": "${name}",
  "pem_file": "${pem_file}",
  "status": "created",
  "created_at": "${timestamp}"
}
EOF
}

# Create JSON for a security group resource
state_security_group_json() {
    local sg_id="$1"
    local sg_name="$2"
    local vpc_id="$3"
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    
    cat << EOF
{
  "id": "${sg_id}",
  "name": "${sg_name}",
  "vpc_id": "${vpc_id}",
  "ports": [22, 80],
  "status": "created",
  "created_at": "${timestamp}"
}
EOF
}

# Create JSON for an EC2 instance resource
state_ec2_json() {
    local instance_id="$1"
    local public_ip="$2"
    local ami_id="$3"
    local key_name="$4"
    local sg_id="$5"
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    
    cat << EOF
{
  "id": "${instance_id}",
  "public_ip": "${public_ip}",
  "ami_id": "${ami_id}",
  "key_name": "${key_name}",
  "security_group_id": "${sg_id}",
  "instance_type": "${INSTANCE_TYPE:-t2.micro}",
  "status": "created",
  "created_at": "${timestamp}"
}
EOF
}

# Create JSON for an S3 bucket resource
state_s3_json() {
    local bucket_name="$1"
    local region="${2:-${AWS_REGION}}"
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
    
    cat << EOF
{
  "name": "${bucket_name}",
  "region": "${region}",
  "versioning": true,
  "objects": ["welcome.txt"],
  "status": "created",
  "created_at": "${timestamp}"
}
EOF
}

# ============================================================================
# S3 Remote State Backend
# ============================================================================
#
# Provides remote state storage in S3 with:
#   - Automatic bucket creation with versioning
#   - Server-side encryption (SSE-S3)
#   - Simple locking via S3 object metadata
#   - Pull/push operations for state synchronization
#

# Get the state bucket name (auto-generate if not set)
_state_get_s3_bucket() {
    if [[ -n "${STATE_S3_BUCKET:-}" ]]; then
        echo "${STATE_S3_BUCKET}"
        return 0
    fi
    
    # Auto-generate bucket name using account ID
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null | tr -d '\r\n' || echo "")
    
    if [[ -z "${account_id}" ]]; then
        log_error "Cannot determine AWS account ID for state bucket name"
        return 1
    fi
    
    echo "${NAME_PREFIX:-automationlab}-tfstate-${account_id}"
}

# Check if S3 backend is enabled
state_is_s3_backend() {
    [[ "${STATE_BACKEND:-local}" == "s3" ]]
}

# Initialize S3 backend - create bucket if needed
# Usage: state_backend_init
state_backend_init() {
    if ! state_is_s3_backend; then
        log_debug "S3 backend not enabled, skipping initialization"
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    local region="${STATE_S3_REGION:-${AWS_REGION:-eu-west-1}}"
    
    log_info "Initializing S3 state backend..."
    log_info "  Bucket: ${bucket_name}"
    log_info "  Region: ${region}"
    log_info "  Key: ${STATE_S3_KEY}"
    
    # Check if bucket exists
    if aws s3api head-bucket --bucket "${bucket_name}" 2>/dev/null; then
        log_info "State bucket already exists: ${bucket_name}"
    else
        log_info "Creating state bucket: ${bucket_name}"
        
        # Create bucket (handle us-east-1 special case)
        if [[ "${region}" == "us-east-1" ]]; then
            aws s3api create-bucket \
                --bucket "${bucket_name}" \
                --region "${region}" || {
                log_error "Failed to create state bucket"
                return 1
            }
        else
            aws s3api create-bucket \
                --bucket "${bucket_name}" \
                --region "${region}" \
                --create-bucket-configuration LocationConstraint="${region}" || {
                log_error "Failed to create state bucket"
                return 1
            }
        fi
        
        log_success "State bucket created: ${bucket_name}"
    fi
    
    # Enable versioning
    log_debug "Enabling versioning on state bucket..."
    aws s3api put-bucket-versioning \
        --bucket "${bucket_name}" \
        --versioning-configuration Status=Enabled || {
        log_warn "Failed to enable versioning on state bucket"
    }
    
    # Enable server-side encryption (SSE-S3)
    if [[ "${STATE_S3_ENCRYPT:-true}" == "true" ]]; then
        log_debug "Enabling server-side encryption..."
        aws s3api put-bucket-encryption \
            --bucket "${bucket_name}" \
            --server-side-encryption-configuration '{
                "Rules": [{
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    }
                }]
            }' 2>/dev/null || log_debug "Encryption may already be configured"
    fi
    
    # Block public access (state should never be public)
    log_debug "Blocking public access to state bucket..."
    aws s3api put-public-access-block \
        --bucket "${bucket_name}" \
        --public-access-block-configuration '{
            "BlockPublicAcls": true,
            "IgnorePublicAcls": true,
            "BlockPublicPolicy": true,
            "RestrictPublicBuckets": true
        }' 2>/dev/null || log_debug "Public access block may already be configured"
    
    # Tag the bucket
    aws s3api put-bucket-tagging \
        --bucket "${bucket_name}" \
        --tagging "TagSet=[{Key=${TAG_KEY:-Project},Value=${PROJECT_TAG:-AutomationLab}},{Key=Purpose,Value=TerraformState}]" \
        2>/dev/null || true
    
    # Export bucket name for other functions
    export STATE_S3_BUCKET="${bucket_name}"
    
    log_success "S3 state backend initialized"
    return 0
}

# Acquire remote lock using S3 object metadata
# Uses a separate lock object in S3
state_lock_remote() {
    if ! state_is_s3_backend; then
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    local lock_key="${STATE_S3_KEY}.lock"
    local timeout="${STATE_LOCK_TIMEOUT:-60}"
    local waited=0
    local lock_holder=""
    
    log_debug "Acquiring remote state lock: s3://${bucket_name}/${lock_key}"
    
    # Check for existing lock
    while true; do
        # Try to get lock info
        lock_holder=$(aws s3api head-object \
            --bucket "${bucket_name}" \
            --key "${lock_key}" \
            --query 'Metadata.lockholder' \
            --output text 2>/dev/null || echo "")
        
        if [[ -z "${lock_holder}" ]] || [[ "${lock_holder}" == "None" ]]; then
            # No lock exists, try to acquire
            break
        fi
        
        # Check lock age via LastModified
        local lock_time
        lock_time=$(aws s3api head-object \
            --bucket "${bucket_name}" \
            --key "${lock_key}" \
            --query 'LastModified' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "${lock_time}" ]]; then
            local lock_epoch
            lock_epoch=$(date -d "${lock_time}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${lock_time%%.*}" +%s 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date +%s)
            local lock_age=$((now_epoch - lock_epoch))
            
            if [[ ${lock_age} -gt ${timeout} ]]; then
                log_warn "Stale remote lock detected (${lock_age}s old), removing..."
                aws s3 rm "s3://${bucket_name}/${lock_key}" 2>/dev/null || true
                break
            fi
        fi
        
        if [[ ${waited} -ge ${timeout} ]]; then
            log_error "Failed to acquire remote state lock after ${timeout}s"
            log_error "Lock held by: ${lock_holder}"
            log_error "To force unlock: ./orchestrate.sh state unlock"
            return 1
        fi
        
        log_debug "Waiting for remote state lock... (${waited}s, held by: ${lock_holder})"
        sleep 2
        waited=$((waited + 2))
    done
    
    # Create lock object with metadata
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")
    local lock_info="pid=$$,host=${hostname},time=$(date -Iseconds)"
    
    echo "Lock acquired by ${lock_info}" | aws s3 cp - "s3://${bucket_name}/${lock_key}" \
        --metadata "lockholder=${lock_info}" \
        --content-type "text/plain" 2>/dev/null || {
        log_error "Failed to create remote lock"
        return 1
    }
    
    log_debug "Remote state lock acquired"
    return 0
}

# Release remote lock
state_unlock_remote() {
    if ! state_is_s3_backend; then
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    local lock_key="${STATE_S3_KEY}.lock"
    
    log_debug "Releasing remote state lock..."
    aws s3 rm "s3://${bucket_name}/${lock_key}" 2>/dev/null || true
    log_debug "Remote state lock released"
}

# Force unlock remote state (for recovery)
state_force_unlock() {
    if ! state_is_s3_backend; then
        log_info "Not using S3 backend, removing local lock only"
        state_unlock
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    local lock_key="${STATE_S3_KEY}.lock"
    
    log_warn "Force unlocking remote state..."
    
    # Show current lock holder
    local lock_holder
    lock_holder=$(aws s3api head-object \
        --bucket "${bucket_name}" \
        --key "${lock_key}" \
        --query 'Metadata.lockholder' \
        --output text 2>/dev/null || echo "none")
    
    if [[ "${lock_holder}" != "none" ]] && [[ "${lock_holder}" != "None" ]]; then
        log_info "Current lock holder: ${lock_holder}"
    fi
    
    aws s3 rm "s3://${bucket_name}/${lock_key}" 2>/dev/null || true
    state_unlock  # Also remove local lock
    
    log_success "State lock forcefully released"
}

# Pull state from S3 to local cache
# Usage: state_pull
state_pull() {
    if ! state_is_s3_backend; then
        log_debug "S3 backend not enabled, skipping pull"
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    local s3_key="${STATE_S3_KEY}"
    
    log_info "Pulling state from S3..."
    log_debug "  Source: s3://${bucket_name}/${s3_key}"
    log_debug "  Dest: ${STATE_FILE}"
    
    # Ensure local state directory exists
    mkdir -p "${STATE_DIR}" 2>/dev/null || true
    
    # Check if remote state exists
    if ! aws s3api head-object --bucket "${bucket_name}" --key "${s3_key}" &>/dev/null; then
        log_info "No remote state found, will create on first push"
        return 0
    fi
    
    # Download state
    aws s3 cp "s3://${bucket_name}/${s3_key}" "${STATE_FILE}" --quiet || {
        log_error "Failed to pull state from S3"
        return 1
    }
    
    log_success "State pulled from S3"
    return 0
}

# Push local state to S3
# Usage: state_push
state_push() {
    if ! state_is_s3_backend; then
        log_debug "S3 backend not enabled, skipping push"
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    local s3_key="${STATE_S3_KEY}"
    
    if [[ ! -f "${STATE_FILE}" ]]; then
        log_warn "No local state file to push"
        return 0
    fi
    
    log_info "Pushing state to S3..."
    log_debug "  Source: ${STATE_FILE}"
    log_debug "  Dest: s3://${bucket_name}/${s3_key}"
    
    # Upload state with server-side encryption
    local extra_args=""
    if [[ "${STATE_S3_ENCRYPT:-true}" == "true" ]]; then
        extra_args="--sse AES256"
    fi
    
    aws s3 cp "${STATE_FILE}" "s3://${bucket_name}/${s3_key}" \
        --content-type "application/json" \
        ${extra_args} --quiet || {
        log_error "Failed to push state to S3"
        return 1
    }
    
    log_success "State pushed to S3"
    return 0
}

# Destroy S3 state backend (bucket and contents)
# Usage: state_backend_destroy [--force]
state_backend_destroy() {
    local force="${1:-}"
    
    if ! state_is_s3_backend; then
        log_warn "S3 backend not enabled"
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || return 1
    
    # Check if bucket exists
    if ! aws s3api head-bucket --bucket "${bucket_name}" 2>/dev/null; then
        log_info "State bucket does not exist: ${bucket_name}"
        return 0
    fi
    
    log_warn "This will PERMANENTLY DELETE the state bucket and ALL state history!"
    log_warn "Bucket: ${bucket_name}"
    
    if [[ "${force}" != "--force" ]] && [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
        echo ""
        read -r -p "Type 'destroy-backend' to confirm: " confirm
        if [[ "${confirm}" != "destroy-backend" ]]; then
            log_info "Backend destruction cancelled"
            return 0
        fi
    fi
    
    log_info "Destroying S3 state backend..."
    
    # Delete all object versions (required for versioned buckets)
    log_debug "Deleting all object versions..."
    
    # Delete versions
    local versions
    versions=$(aws s3api list-object-versions \
        --bucket "${bucket_name}" \
        --query 'Versions[*].[Key,VersionId]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${versions}" ]]; then
        while IFS=$'\t' read -r key version_id; do
            if [[ -n "${key}" ]] && [[ -n "${version_id}" ]] && [[ "${key}" != "None" ]]; then
                aws s3api delete-object \
                    --bucket "${bucket_name}" \
                    --key "${key}" \
                    --version-id "${version_id}" >/dev/null 2>&1 || true
            fi
        done <<< "${versions}"
    fi
    
    # Delete delete markers
    local markers
    markers=$(aws s3api list-object-versions \
        --bucket "${bucket_name}" \
        --query 'DeleteMarkers[*].[Key,VersionId]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${markers}" ]]; then
        while IFS=$'\t' read -r key version_id; do
            if [[ -n "${key}" ]] && [[ -n "${version_id}" ]] && [[ "${key}" != "None" ]]; then
                aws s3api delete-object \
                    --bucket "${bucket_name}" \
                    --key "${key}" \
                    --version-id "${version_id}" >/dev/null 2>&1 || true
            fi
        done <<< "${markers}"
    fi
    
    # Delete bucket
    log_debug "Deleting bucket..."
    aws s3 rb "s3://${bucket_name}" --force 2>/dev/null || {
        log_error "Failed to delete state bucket"
        return 1
    }
    
    log_success "S3 state backend destroyed: ${bucket_name}"
    return 0
}

# Show S3 backend status
state_backend_status() {
    if ! state_is_s3_backend; then
        echo "Backend: local"
        echo "State file: ${STATE_FILE}"
        return 0
    fi
    
    local bucket_name
    bucket_name=$(_state_get_s3_bucket) || {
        echo "Backend: s3 (not configured)"
        return 1
    }
    
    echo "Backend: s3"
    echo "Bucket: ${bucket_name}"
    echo "Key: ${STATE_S3_KEY}"
    echo "Region: ${STATE_S3_REGION:-${AWS_REGION}}"
    echo "Encryption: ${STATE_S3_ENCRYPT:-true}"
    echo ""
    
    # Check bucket status
    if aws s3api head-bucket --bucket "${bucket_name}" 2>/dev/null; then
        echo "Bucket Status: EXISTS"
        
        # Check for lock
        local lock_key="${STATE_S3_KEY}.lock"
        local lock_holder
        lock_holder=$(aws s3api head-object \
            --bucket "${bucket_name}" \
            --key "${lock_key}" \
            --query 'Metadata.lockholder' \
            --output text 2>/dev/null || echo "")
        
        if [[ -n "${lock_holder}" ]] && [[ "${lock_holder}" != "None" ]]; then
            echo "Lock Status: LOCKED by ${lock_holder}"
        else
            echo "Lock Status: UNLOCKED"
        fi
        
        # Check state file
        if aws s3api head-object --bucket "${bucket_name}" --key "${STATE_S3_KEY}" &>/dev/null; then
            local last_modified
            last_modified=$(aws s3api head-object \
                --bucket "${bucket_name}" \
                --key "${STATE_S3_KEY}" \
                --query 'LastModified' \
                --output text 2>/dev/null || echo "unknown")
            echo "State File: EXISTS (modified: ${last_modified})"
        else
            echo "State File: NOT FOUND"
        fi
    else
        echo "Bucket Status: DOES NOT EXIST"
    fi
}

# Wrapper for state_init that handles S3 backend
# Call this instead of state_init directly
state_init_with_backend() {
    # Initialize S3 backend if enabled
    if state_is_s3_backend; then
        state_backend_init || return 1
        state_lock_remote || return 1
        state_pull || return 1
    fi
    
    # Initialize local state
    state_init
    
    return 0
}

# Wrapper for state operations that syncs with S3
# Call this after any state modification
state_sync() {
    if state_is_s3_backend; then
        state_push || return 1
    fi
    return 0
}

