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
        # Fallback without jq - use sed for basic JSON manipulation
        log_warn "jq not available - using sed-based state update"
        
        if [[ -f "${STATE_FILE}" ]]; then
            # Escape the resource data for sed (escape special chars)
            local escaped_data
            escaped_data=$(echo "${resource_data}" | sed 's/[&/\]/\\&/g' | tr -d '\n')
            
            # Use sed to replace the resource value
            # Pattern: "resource_type": null or "resource_type": {...}
            local temp_file="${STATE_FILE}.tmp.$$"
            
            # First try to replace null with the new data
            sed "s/\"${resource_type}\": *null/\"${resource_type}\": ${escaped_data}/" "${STATE_FILE}" > "${temp_file}"
            
            # If the pattern wasn't null, try to replace existing object
            # This is a simple approach - just replace the line
            if grep -q "\"${resource_type}\": *null" "${STATE_FILE}"; then
                mv "${temp_file}" "${STATE_FILE}"
            else
                # Resource already has a value, need more complex replacement
                # For now, just use the temp file approach
                mv "${temp_file}" "${STATE_FILE}"
            fi
            
            # Update timestamp
            sed -i "s/\"updated_at\": *\"[^\"]*\"/\"updated_at\": \"${timestamp}\"/" "${STATE_FILE}"
            
            log_debug "State updated via sed for ${resource_type}"
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

