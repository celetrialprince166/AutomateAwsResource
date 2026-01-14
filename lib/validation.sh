#!/usr/bin/env bash
#
# validation.sh - Input Validation Library
#
# Provides robust input validation for AWS resource parameters.
# Catches common errors before they reach AWS API, providing better error messages.
#
# Features:
#   - S3 bucket name validation (AWS naming rules)
#   - AWS region validation
#   - EC2 instance type validation
#   - Security group name validation
#   - Key pair name validation
#   - IP/CIDR validation
#
# Usage:
#   source lib/validation.sh
#   validate_bucket_name "my-bucket" || exit 1
#   validate_region "us-east-1" || exit 1
#
# Author: AutomationLab Project
# Version: 1.0.0
#

# Prevent multiple sourcing
[[ -n "${_VALIDATION_SH_LOADED:-}" ]] && return 0
readonly _VALIDATION_SH_LOADED=1

# ============================================================================
# Dependencies
# ============================================================================

# Ensure logging is available
if ! declare -f log_error &>/dev/null; then
    _VAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${_VAL_LIB_DIR}/logging.sh"
fi

# ============================================================================
# AWS Region Validation
# ============================================================================

# List of valid AWS regions (as of 2024)
# This list should be periodically updated
readonly VALID_AWS_REGIONS=(
    "us-east-1"
    "us-east-2"
    "us-west-1"
    "us-west-2"
    "af-south-1"
    "ap-east-1"
    "ap-south-1"
    "ap-south-2"
    "ap-southeast-1"
    "ap-southeast-2"
    "ap-southeast-3"
    "ap-southeast-4"
    "ap-northeast-1"
    "ap-northeast-2"
    "ap-northeast-3"
    "ca-central-1"
    "ca-west-1"
    "eu-central-1"
    "eu-central-2"
    "eu-west-1"
    "eu-west-2"
    "eu-west-3"
    "eu-south-1"
    "eu-south-2"
    "eu-north-1"
    "il-central-1"
    "me-south-1"
    "me-central-1"
    "sa-east-1"
)

# Validate AWS region
# Returns: 0 if valid, 1 if invalid
validate_region() {
    local region="$1"
    
    if [[ -z "${region}" ]]; then
        log_error "Region cannot be empty"
        return 1
    fi
    
    # Check against known regions
    for valid_region in "${VALID_AWS_REGIONS[@]}"; do
        if [[ "${region}" == "${valid_region}" ]]; then
            log_debug "Region '${region}' is valid"
            return 0
        fi
    done
    
    # Check format even if not in list (new regions)
    if [[ "${region}" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        log_warn "Region '${region}' not in known list but format is valid"
        return 0
    fi
    
    log_error "Invalid region: '${region}'"
    log_error "Must be a valid AWS region (e.g., us-east-1, eu-west-2)"
    return 1
}

# ============================================================================
# S3 Bucket Name Validation
# ============================================================================

# Validate S3 bucket name according to AWS naming rules
# Rules:
#   - 3-63 characters long
#   - Only lowercase letters, numbers, and hyphens
#   - Must start and end with letter or number
#   - Cannot be formatted as IP address
#   - Must be globally unique (can't check this locally)
validate_bucket_name() {
    local name="$1"
    
    if [[ -z "${name}" ]]; then
        log_error "Bucket name cannot be empty"
        return 1
    fi
    
    # Check length
    local length=${#name}
    if [[ ${length} -lt 3 ]] || [[ ${length} -gt 63 ]]; then
        log_error "Bucket name must be 3-63 characters long (got ${length})"
        return 1
    fi
    
    # Check for uppercase (common mistake)
    if [[ "${name}" =~ [A-Z] ]]; then
        log_error "Bucket name must be lowercase"
        log_error "Suggested: $(echo "${name}" | tr '[:upper:]' '[:lower:]')"
        return 1
    fi
    
    # Check for invalid characters
    if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] && [[ ${length} -gt 2 ]]; then
        log_error "Bucket name must start and end with letter or number"
        log_error "Only lowercase letters, numbers, hyphens, and dots allowed"
        return 1
    fi
    
    # Check for consecutive dots
    if [[ "${name}" =~ \.\. ]]; then
        log_error "Bucket name cannot contain consecutive dots"
        return 1
    fi
    
    # Check for IP address format
    if [[ "${name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Bucket name cannot be formatted as an IP address"
        return 1
    fi
    
    # Check for underscore (common mistake)
    if [[ "${name}" =~ _ ]]; then
        log_error "Bucket name cannot contain underscores"
        log_error "Suggested: ${name//_/-}"
        return 1
    fi
    
    log_debug "Bucket name '${name}' is valid"
    return 0
}

# Sanitize a string to be a valid bucket name
# Returns: sanitized name
sanitize_bucket_name() {
    local name="$1"
    
    # Convert to lowercase
    name=$(echo "${name}" | tr '[:upper:]' '[:lower:]')
    
    # Replace underscores with hyphens
    name="${name//_/-}"
    
    # Remove invalid characters
    name=$(echo "${name}" | sed 's/[^a-z0-9.-]//g')
    
    # Remove consecutive dots/hyphens
    name=$(echo "${name}" | sed 's/\.\./-/g' | sed 's/--/-/g')
    
    # Ensure starts with alphanumeric
    name=$(echo "${name}" | sed 's/^[^a-z0-9]*//')
    
    # Ensure ends with alphanumeric
    name=$(echo "${name}" | sed 's/[^a-z0-9]*$//')
    
    # Truncate to 63 characters
    name="${name:0:63}"
    
    echo "${name}"
}

# ============================================================================
# Security Group Validation
# ============================================================================

# Validate security group name
# Rules:
#   - 1-255 characters
#   - a-z, A-Z, 0-9, spaces, and ._-:/()#,@[]+=&;{}!$*
validate_security_group_name() {
    local name="$1"
    
    if [[ -z "${name}" ]]; then
        log_error "Security group name cannot be empty"
        return 1
    fi
    
    local length=${#name}
    if [[ ${length} -gt 255 ]]; then
        log_error "Security group name must be 255 characters or less (got ${length})"
        return 1
    fi
    
    # AWS allows most printable characters, but let's be conservative
    if [[ ! "${name}" =~ ^[a-zA-Z0-9\ ._:/@#,\[\]+=\&\;\{\}\!\$\*-]+$ ]]; then
        log_error "Security group name contains invalid characters"
        return 1
    fi
    
    log_debug "Security group name '${name}' is valid"
    return 0
}

# Validate security group ID format
validate_security_group_id() {
    local sg_id="$1"
    
    # Strip all whitespace (handles newlines, spaces, tabs)
    sg_id="${sg_id//[$'\t\r\n ']/}"
    
    if [[ -z "${sg_id}" ]]; then
        log_error "Security group ID cannot be empty"
        return 1
    fi
    
    if [[ ! "${sg_id}" =~ ^sg-[a-f0-9]{8,17}$ ]]; then
        log_error "Invalid security group ID format: '${sg_id}'"
        log_error "Expected format: sg-xxxxxxxx or sg-xxxxxxxxxxxxxxxxx"
        return 1
    fi
    
    log_debug "Security group ID '${sg_id}' format is valid"
    return 0
}

# ============================================================================
# EC2 Validation
# ============================================================================

# Common free-tier eligible instance types
readonly FREE_TIER_INSTANCE_TYPES=(
    "t3.micro"
)

# Validate EC2 instance type format
validate_instance_type() {
    local itype="$1"
    
    if [[ -z "${itype}" ]]; then
        log_error "Instance type cannot be empty"
        return 1
    fi
    
    # Basic format check: family.size
    if [[ ! "${itype}" =~ ^[a-z][a-z0-9]*\.[a-z0-9]+$ ]]; then
        log_error "Invalid instance type format: '${itype}'"
        log_error "Expected format: family.size (e.g., t2.micro, m5.large)"
        return 1
    fi
    
    # Warn if not free-tier eligible
    local is_free_tier=false
    for ft_type in "${FREE_TIER_INSTANCE_TYPES[@]}"; do
        if [[ "${itype}" == "${ft_type}" ]]; then
            is_free_tier=true
            break
        fi
    done
    
    if [[ "${is_free_tier}" == "false" ]]; then
        log_warn "Instance type '${itype}' may not be free-tier eligible"
        log_warn "Free tier types: ${FREE_TIER_INSTANCE_TYPES[*]}"
    fi
    
    log_debug "Instance type '${itype}' is valid"
    return 0
}

# Validate EC2 instance ID format
validate_instance_id() {
    local instance_id="$1"
    
    # Strip all whitespace
    instance_id="${instance_id//[$'\t\r\n ']/}"
    
    if [[ ! "${instance_id}" =~ ^i-[a-f0-9]{8,17}$ ]]; then
        log_error "Invalid instance ID format: '${instance_id}'"
        log_error "Expected format: i-xxxxxxxx or i-xxxxxxxxxxxxxxxxx"
        return 1
    fi
    
    log_debug "Instance ID '${instance_id}' format is valid"
    return 0
}

# Validate key pair name
validate_key_pair_name() {
    local name="$1"
    
    if [[ -z "${name}" ]]; then
        log_error "Key pair name cannot be empty"
        return 1
    fi
    
    local length=${#name}
    if [[ ${length} -gt 255 ]]; then
        log_error "Key pair name must be 255 characters or less"
        return 1
    fi
    
    # Key pair names have similar rules to security groups
    if [[ ! "${name}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Key pair name contains invalid characters"
        log_error "Allowed: letters, numbers, dots, underscores, hyphens"
        return 1
    fi
    
    log_debug "Key pair name '${name}' is valid"
    return 0
}

# Validate AMI ID format
validate_ami_id() {
    local ami_id="$1"
    
    # Strip all whitespace
    ami_id="${ami_id//[$'\t\r\n ']/}"
    
    if [[ ! "${ami_id}" =~ ^ami-[a-f0-9]{8,17}$ ]]; then
        log_error "Invalid AMI ID format: '${ami_id}'"
        log_error "Expected format: ami-xxxxxxxx or ami-xxxxxxxxxxxxxxxxx"
        return 1
    fi
    
    log_debug "AMI ID '${ami_id}' format is valid"
    return 0
}

# ============================================================================
# Network Validation
# ============================================================================

# Validate CIDR notation
validate_cidr() {
    local cidr="$1"
    
    # Pattern: x.x.x.x/y where x is 0-255 and y is 0-32
    if [[ ! "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_error "Invalid CIDR format: '${cidr}'"
        log_error "Expected format: x.x.x.x/y (e.g., 10.0.0.0/16, 0.0.0.0/0)"
        return 1
    fi
    
    # Extract IP and prefix
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    
    # Validate prefix (0-32)
    if [[ ${prefix} -lt 0 ]] || [[ ${prefix} -gt 32 ]]; then
        log_error "CIDR prefix must be between 0 and 32 (got ${prefix})"
        return 1
    fi
    
    # Validate IP octets
    IFS='.' read -ra octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        if [[ ${octet} -lt 0 ]] || [[ ${octet} -gt 255 ]]; then
            log_error "Invalid IP octet: ${octet} (must be 0-255)"
            return 1
        fi
    done
    
    log_debug "CIDR '${cidr}' is valid"
    return 0
}

# Validate port number
validate_port() {
    local port="$1"
    local name="${2:-Port}"
    
    # Check if numeric
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        log_error "${name} must be a number (got '${port}')"
        return 1
    fi
    
    # Check range
    if [[ ${port} -lt 1 ]] || [[ ${port} -gt 65535 ]]; then
        log_error "${name} must be between 1 and 65535 (got ${port})"
        return 1
    fi
    
    log_debug "${name} ${port} is valid"
    return 0
}

# Validate VPC ID format
validate_vpc_id() {
    local vpc_id="$1"
    
    # Strip all whitespace
    vpc_id="${vpc_id//[$'\t\r\n ']/}"
    
    if [[ ! "${vpc_id}" =~ ^vpc-[a-f0-9]{8,17}$ ]]; then
        log_error "Invalid VPC ID format: '${vpc_id}'"
        log_error "Expected format: vpc-xxxxxxxx or vpc-xxxxxxxxxxxxxxxxx"
        return 1
    fi
    
    log_debug "VPC ID '${vpc_id}' format is valid"
    return 0
}

# ============================================================================
# General Validation Helpers
# ============================================================================

# Validate that a value is not empty
validate_not_empty() {
    local value="$1"
    local name="${2:-Value}"
    
    if [[ -z "${value}" ]]; then
        log_error "${name} cannot be empty"
        return 1
    fi
    
    return 0
}

# Validate that a value matches a pattern
validate_pattern() {
    local value="$1"
    local pattern="$2"
    local name="${3:-Value}"
    
    if [[ ! "${value}" =~ ${pattern} ]]; then
        log_error "${name} '${value}' does not match required pattern"
        return 1
    fi
    
    return 0
}

# Run multiple validations, collecting all errors
# Usage: validate_all errors "field1:value1:validator1" "field2:value2:validator2"
# Returns: 0 if all pass, 1 if any fail
validate_all() {
    local -n error_array=$1
    shift
    local failed=0
    
    for validation in "$@"; do
        IFS=':' read -r field value validator <<< "${validation}"
        
        if ! "${validator}" "${value}"; then
            error_array+=("${field}: validation failed")
            failed=1
        fi
    done
    
    return ${failed}
}

