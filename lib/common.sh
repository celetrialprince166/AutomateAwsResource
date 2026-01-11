#!/usr/bin/env bash
#
# common.sh - Shared utility library for AWS Automation Scripts
#
# This library provides DRY (Don't Repeat Yourself) functionality used across
# all scripts in the project. It handles:
#   - Configuration loading
#   - AWS CLI wrapper with retry logic
#   - Prerequisite validation
#   - Platform compatibility
#   - Error handling
#   - Resource tagging
#
# Usage:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../lib/common.sh"
#   init_script
#   # Your script logic here...
#
# Author: AutomationLab Project
# Version: 1.0.0
#

# Prevent multiple sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
readonly _COMMON_SH_LOADED=1

# ============================================================================
# Strict Mode & Error Handling
# ============================================================================

# Enable strict mode if not already set
set -o errexit   # Exit on error
set -o nounset   # Error on undefined variables
set -o pipefail  # Pipeline fails on first error

# ============================================================================
# Path Resolution
# ============================================================================

# Get the directory where this library is located
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "${_LIB_DIR}/.." && pwd)"

# ============================================================================
# Load Dependencies
# ============================================================================

# Source configuration first (provides all defaults)
# shellcheck source=../config.env
source "${_PROJECT_ROOT}/config.env"

# Source logging module
# shellcheck source=./logging.sh
source "${_LIB_DIR}/logging.sh"

# ============================================================================
# Platform Detection
# ============================================================================

# Detect if running on Windows (Git Bash, WSL, etc.)
is_windows() {
    [[ "${OSTYPE:-}" == "msys" ]] || \
    [[ "${OSTYPE:-}" == "cygwin" ]] || \
    [[ -n "${WINDIR:-}" ]] || \
    [[ "$(uname -s)" == MINGW* ]] || \
    [[ "$(uname -s)" == CYGWIN* ]]
}

# Detect if running on macOS
is_macos() {
    [[ "${OSTYPE:-}" == "darwin"* ]] || [[ "$(uname -s)" == "Darwin" ]]
}

# Detect if running on Linux
is_linux() {
    [[ "${OSTYPE:-}" == "linux-gnu"* ]] || [[ "$(uname -s)" == "Linux" ]]
}

# Get platform-appropriate temp directory
get_temp_dir() {
    if [[ -n "${TMPDIR:-}" ]]; then
        echo "${TMPDIR}"
    elif [[ -d "/tmp" ]]; then
        echo "/tmp"
    elif is_windows; then
        echo "${TEMP:-${TMP:-/tmp}}"
    else
        echo "/tmp"
    fi
}

# ============================================================================
# Prerequisite Validation
# ============================================================================

# Check if AWS CLI is installed and accessible
check_aws_cli() {
    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI is not installed or not in PATH"
        log_error "Install it from: https://aws.amazon.com/cli/"
        return 1
    fi

    # Check AWS CLI version (prefer v2)
    local version
    version=$(aws --version 2>&1 | head -1)
    log_debug "AWS CLI version: ${version}"
    return 0
}

# Check if jq is available (optional but recommended)
check_jq() {
    if command -v jq &>/dev/null; then
        log_debug "jq is available"
        return 0
    else
        log_warn "jq is not installed - some features may be limited"
        log_warn "Install jq for better JSON handling: https://stedolan.github.io/jq/"
        return 1
    fi
}

# Validate AWS credentials are configured and working
check_aws_credentials() {
    log_debug "Validating AWS credentials..."
    
    local identity
    if ! identity=$(aws_cmd sts get-caller-identity --output json 2>&1); then
        log_error "AWS credentials are not configured or have expired"
        log_error "Run 'aws configure' to set up credentials or check your profile"
        log_error "AWS CLI output: ${identity}"
        return 1
    fi

    # Extract account info for logging
    local account_id arn
    if command -v jq &>/dev/null; then
        account_id=$(echo "${identity}" | jq -r '.Account')
        arn=$(echo "${identity}" | jq -r '.Arn')
    else
        account_id=$(echo "${identity}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
        arn=$(echo "${identity}" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)
    fi

    log_info "AWS Account: ${account_id}"
    log_debug "Caller ARN: ${arn}"
    
    # Store for later use
    export AWS_ACCOUNT_ID="${account_id}"
    
    return 0
}

# Run all prerequisite checks
check_prerequisites() {
    log_debug "Running prerequisite checks..."
    local failed=0

    check_aws_cli || failed=1
    
    if [[ ${failed} -eq 1 ]]; then
        log_fatal "Prerequisites not met. Please fix the issues above and try again." 1
    fi

    # Check credentials (non-fatal for --help type commands)
    check_aws_credentials || failed=1
    
    # jq is optional
    check_jq || true

    if [[ ${failed} -eq 1 ]]; then
        log_fatal "AWS credentials validation failed" 1
    fi

    log_success "All prerequisites satisfied"
    return 0
}

# ============================================================================
# AWS CLI Wrapper with Retry Logic
# ============================================================================

# Unified AWS CLI wrapper with region/profile handling and retry logic
# Usage: aws_cmd ec2 describe-instances --filters ...
aws_cmd() {
    local cmd_args=("$@")
    local attempt=1
    local max_attempts="${MAX_RETRIES:-3}"
    local delay="${RETRY_DELAY:-2}"
    local output
    local exit_code

    while [[ ${attempt} -le ${max_attempts} ]]; do
        log_debug "AWS CLI: aws ${cmd_args[*]} (attempt ${attempt}/${max_attempts})"
        
        # Build command with region and profile
        set +e
        output=$(aws --region "${AWS_REGION}" \
            ${AWS_PROFILE:+--profile "${AWS_PROFILE}"} \
            "${cmd_args[@]}" 2>&1)
        exit_code=$?
        set -e

        if [[ ${exit_code} -eq 0 ]]; then
            echo "${output}"
            return 0
        fi

        # Check if error is retryable
        if echo "${output}" | grep -qiE "(throttl|rate exceed|try again|timeout|connection)"; then
            log_warn "Transient error detected, retrying in ${delay}s..."
            log_debug "Error: ${output}"
            sleep "${delay}"
            delay=$((delay * 2))  # Exponential backoff
            attempt=$((attempt + 1))
        else
            # Non-retryable error
            log_error "AWS CLI command failed: ${output}"
            return ${exit_code}
        fi
    done

    log_error "AWS CLI command failed after ${max_attempts} attempts"
    log_error "Last error: ${output}"
    return 1
}

# ============================================================================
# Resource Tagging Helpers
# ============================================================================

# Get the standard tag specification for resource creation
# Usage: get_tag_spec "instance" 
# Returns: ResourceType=instance,Tags=[{Key=Project,Value=AutomationLab}]
get_tag_spec() {
    local resource_type="${1:-instance}"
    echo "ResourceType=${resource_type},Tags=[{Key=${TAG_KEY},Value=${PROJECT_TAG}}]"
}

# Apply tags to an existing resource
# Usage: apply_tags "i-1234567890abcdef0" "ec2"
apply_tags() {
    local resource_id="$1"
    local service="${2:-ec2}"
    
    log_debug "Applying tags to ${resource_id}: ${TAG_KEY}=${PROJECT_TAG}"
    
    case "${service}" in
        ec2|security-group|sg)
            aws_cmd ec2 create-tags \
                --resources "${resource_id}" \
                --tags "Key=${TAG_KEY},Value=${PROJECT_TAG}"
            ;;
        s3)
            aws_cmd s3api put-bucket-tagging \
                --bucket "${resource_id}" \
                --tagging "TagSet=[{Key=${TAG_KEY},Value=${PROJECT_TAG}}]"
            ;;
        *)
            log_warn "Unknown service type for tagging: ${service}"
            return 1
            ;;
    esac
    
    log_debug "Tags applied successfully"
    return 0
}

# ============================================================================
# VPC Helpers
# ============================================================================

# Get the default VPC ID for the current region
get_default_vpc() {
    log_debug "Looking up default VPC in region ${AWS_REGION}..."
    
    local vpc_id
    vpc_id=$(aws_cmd ec2 describe-vpcs \
        --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' \
        --output text | tr -d '\r\n' | xargs)
    
    if [[ -z "${vpc_id}" ]] || [[ "${vpc_id}" == "None" ]]; then
        log_error "No default VPC found in region ${AWS_REGION}"
        log_error "Create a default VPC with: aws ec2 create-default-vpc"
        return 1
    fi
    
    log_debug "Default VPC: ${vpc_id}"
    echo "${vpc_id}"
}

# ============================================================================
# File & Permission Helpers
# ============================================================================

# Safe chmod that handles Windows gracefully
# On Windows, chmod doesn't work as expected, so we log a warning
safe_chmod() {
    local mode="$1"
    local file="$2"
    
    if is_windows; then
        log_warn "chmod ${mode} ${file} - skipped on Windows"
        log_warn "On Windows, use SSH agent or ensure file is not world-readable"
        return 0
    fi
    
    chmod "${mode}" "${file}"
    log_debug "Set permissions ${mode} on ${file}"
}

# Create directory if it doesn't exist
ensure_dir() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        log_debug "Created directory: ${dir}"
    fi
}

# ============================================================================
# User Confirmation
# ============================================================================

# Prompt user for confirmation
# Returns 0 if confirmed, 1 if declined
# Skips prompt if AUTO_APPROVE=true
confirm() {
    local message="${1:-Are you sure?}"
    
    # Auto-approve if flag is set
    if [[ "${AUTO_APPROVE:-false}" == "true" ]]; then
        log_debug "Auto-approved: ${message}"
        return 0
    fi
    
    # Skip if not interactive
    if [[ ! -t 0 ]]; then
        log_warn "Non-interactive mode, assuming 'no'"
        return 1
    fi
    
    echo -n "${message} [y/N]: " >&2
    local response
    read -r response
    
    case "${response}" in
        [yY]|[yY][eE][sS])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# Script Initialization
# ============================================================================

# Standard script initialization - call at the start of every script
# This sets up logging, validates prerequisites, and prints startup info
init_script() {
    local script_name="${SCRIPT_NAME_OVERRIDE:-$(basename "${BASH_SOURCE[1]:-$0}")}"
    
    # Initialize logger with script name
    init_logger --script-name "${script_name}"
    
    # Print startup banner in debug mode
    if is_debug_enabled; then
        log_separator "="
        log_info "Script: ${script_name}"
        log_info "Started: $(date -Iseconds 2>/dev/null || date)"
        log_separator "-"
        log_kv "Region" "${AWS_REGION}"
        log_kv "Profile" "${AWS_PROFILE}"
        log_kv "Project Tag" "${PROJECT_TAG}"
        log_kv "Name Prefix" "${NAME_PREFIX}"
        log_kv "Platform" "$(uname -s)"
        log_separator "="
    else
        log_info "Using Region=${AWS_REGION}, Profile=${AWS_PROFILE}"
    fi
    
    # Run prerequisite checks
    check_prerequisites
}

# ============================================================================
# Cleanup Trap Handler
# ============================================================================

# Array to store cleanup functions
declare -a _CLEANUP_HANDLERS=()

# Register a cleanup function to be called on exit
# Usage: register_cleanup "cleanup_function_name"
register_cleanup() {
    local handler="$1"
    _CLEANUP_HANDLERS+=("${handler}")
    log_debug "Registered cleanup handler: ${handler}"
}

# Internal cleanup dispatcher
_run_cleanup_handlers() {
    local exit_code=$?
    
    if [[ ${#_CLEANUP_HANDLERS[@]} -gt 0 ]]; then
        log_debug "Running ${#_CLEANUP_HANDLERS[@]} cleanup handlers..."
        for handler in "${_CLEANUP_HANDLERS[@]}"; do
            log_debug "Running cleanup: ${handler}"
            "${handler}" || true
        done
    fi
    
    exit ${exit_code}
}

# Set up trap for cleanup on exit
trap _run_cleanup_handlers EXIT

# ============================================================================
# Dry Run Support
# ============================================================================

# Check if dry run mode is enabled
is_dry_run() {
    [[ "${DRY_RUN:-false}" == "true" ]]
}

# Execute command only if not in dry run mode
# In dry run mode, logs what would be done
# Usage: maybe_run aws_cmd ec2 run-instances ...
maybe_run() {
    if is_dry_run; then
        log_info "[DRY RUN] Would execute: $*"
        return 0
    else
        "$@"
    fi
}

# ============================================================================
# Output Helpers
# ============================================================================

# Print a summary box with key information
# Usage: print_summary "EC2 Instance Details" "key1:value1" "key2:value2" ...
print_summary() {
    local title="$1"
    shift
    local pairs=("$@")
    
    local width=60
    local border
    border=$(printf '%*s' ${width} '' | tr ' ' '=')
    
    echo ""
    echo "${border}"
    echo " ${title}"
    echo "${border}"
    
    for pair in "${pairs[@]}"; do
        local key="${pair%%:*}"
        local value="${pair#*:}"
        printf " %-20s %s\n" "${key}:" "${value}"
    done
    
    echo "${border}"
    echo ""
}

# ============================================================================
# JSON Helpers (work with or without jq)
# ============================================================================

# Extract a value from JSON using jq if available, fallback to grep
# Usage: json_get '{"key": "value"}' '.key'
json_get() {
    local json="$1"
    local path="$2"
    
    if command -v jq &>/dev/null; then
        echo "${json}" | jq -r "${path}"
    else
        # Basic fallback for simple paths like '.Key'
        local key="${path#.}"
        echo "${json}" | grep -o "\"${key}\": *\"[^\"]*\"" | cut -d'"' -f4
    fi
}

