#!/usr/bin/env bash
#
# logging.sh - Enhanced logging module for bash scripts
# 
# Inspired by industry best practices and Graham Watts' logging module approach.
# Provides consistent, colorized, level-based logging with file and console output.
#
# Features:
#   - Log levels: DEBUG, INFO, WARN, ERROR, SUCCESS
#   - ISO 8601 timestamps for easy parsing and correlation
#   - Color-coded console output (can be disabled)
#   - Dual output: stderr (console) + log file
#   - Runtime log level configuration
#   - Script name included in all messages
#   - Sensitive data logging (console only, no file)
#   - Structured format for grep/log analysis tools
#
# Usage:
#   source lib/logging.sh
#   init_logger --log "/path/to/file.log" --level INFO
#   log_info "This is an informational message"
#   log_debug "This is a debug message"  # Only shown if level is DEBUG
#
# Environment Variables:
#   LOG_LEVEL    - Minimum level to log (DEBUG|INFO|WARN|ERROR) default: INFO
#   LOG_FILE     - Path to log file (default: ./<script_name>.log)
#   NO_COLOR     - Set to disable colored output (respects NO_COLOR standard)
#   LOG_TO_FILE  - Set to "false" to disable file logging (default: true)
#
# Author: AutomationLab Project
# Version: 2.0.0
#

# Prevent multiple sourcing
[[ -n "${_LOGGING_SH_LOADED:-}" ]] && return 0
readonly _LOGGING_SH_LOADED=1

# ============================================================================
# Configuration Defaults
# ============================================================================

# Script name for log messages (can be overridden before sourcing)
_LOG_SCRIPT_NAME="${SCRIPT_NAME_OVERRIDE:-$(basename "${BASH_SOURCE[1]:-${0}}")}"

# Default log level
_LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Default log file (in current directory, named after calling script)
_LOG_FILE="${LOG_FILE:-"./${_LOG_SCRIPT_NAME%.sh}.log"}"

# File logging enabled by default
_LOG_TO_FILE="${LOG_TO_FILE:-true}"

# ============================================================================
# Color Definitions (respects NO_COLOR standard: https://no-color.org/)
# ============================================================================

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 2 ]]; then
    # Terminal supports colors and NO_COLOR not set
    readonly _CLR_RESET='\033[0m'
    readonly _CLR_RED='\033[0;31m'
    readonly _CLR_GREEN='\033[0;32m'
    readonly _CLR_YELLOW='\033[0;33m'
    readonly _CLR_BLUE='\033[0;34m'
    readonly _CLR_CYAN='\033[0;36m'
    readonly _CLR_BOLD='\033[1m'
    readonly _CLR_DIM='\033[2m'
else
    # No colors
    readonly _CLR_RESET=''
    readonly _CLR_RED=''
    readonly _CLR_GREEN=''
    readonly _CLR_YELLOW=''
    readonly _CLR_BLUE=''
    readonly _CLR_CYAN=''
    readonly _CLR_BOLD=''
    readonly _CLR_DIM=''
fi

# ============================================================================
# Log Level Mapping
# ============================================================================

# Map level names to numeric values for comparison
# Lower number = more verbose
_log_level_to_num() {
    case "${1^^}" in
        DEBUG)   echo 10 ;;
        INFO)    echo 20 ;;
        SUCCESS) echo 20 ;;  # Same priority as INFO
        WARN)    echo 30 ;;
        WARNING) echo 30 ;;
        ERROR)   echo 40 ;;
        *)       echo 20 ;;  # Default to INFO
    esac
}

# Check if a message at given level should be logged
_should_log() {
    local msg_level="$1"
    local current_level="${_LOG_LEVEL:-INFO}"
    [[ "$(_log_level_to_num "$msg_level")" -ge "$(_log_level_to_num "$current_level")" ]]
}

# ============================================================================
# Logger Initialization
# ============================================================================

# Initialize the logger with optional parameters
# Usage: init_logger [--log FILE] [--level LEVEL] [--no-file]
init_logger() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log)
                _LOG_FILE="$2"
                shift 2
                ;;
            --level)
                _LOG_LEVEL="${2^^}"  # Uppercase
                shift 2
                ;;
            --no-file)
                _LOG_TO_FILE="false"
                shift
                ;;
            --script-name)
                _LOG_SCRIPT_NAME="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Create log directory if it doesn't exist and file logging is enabled
    if [[ "${_LOG_TO_FILE}" == "true" ]] && [[ -n "${_LOG_FILE}" ]]; then
        local log_dir
        log_dir="$(dirname "${_LOG_FILE}")"
        if [[ ! -d "${log_dir}" ]] && [[ "${log_dir}" != "." ]]; then
            mkdir -p "${log_dir}" 2>/dev/null || true
        fi
    fi
}

# ============================================================================
# Core Logging Function
# ============================================================================

# Internal logging function - do not call directly
# Args: LEVEL COLOR MESSAGE...
_log() {
    local level="$1"
    local color="$2"
    shift 2
    local message="$*"

    # Check if we should log this level
    if ! _should_log "$level"; then
        return 0
    fi

    # Generate ISO 8601 timestamp
    # Try GNU date first, fall back to BSD/macOS date
    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

    # Pad level to fixed width for alignment
    local level_padded
    level_padded=$(printf '%-7s' "$level")

    # Construct log message (structured format for easy parsing)
    # Format: [TIMESTAMP] [LEVEL] [SCRIPT] MESSAGE
    local log_msg="[${timestamp}] [${level_padded}] [${_LOG_SCRIPT_NAME}] ${message}"

    # Console output (colored) to stderr
    local console_msg="${_CLR_DIM}[${timestamp}]${_CLR_RESET} ${color}[${level_padded}]${_CLR_RESET} ${_CLR_CYAN}[${_LOG_SCRIPT_NAME}]${_CLR_RESET} ${message}"
    echo -e "${console_msg}" >&2

    # File output (no colors) - append to log file
    if [[ "${_LOG_TO_FILE}" == "true" ]] && [[ -n "${_LOG_FILE}" ]]; then
        echo "${log_msg}" >> "${_LOG_FILE}" 2>/dev/null || true
    fi
}

# ============================================================================
# Public Logging Functions
# ============================================================================

# Debug level - detailed information for troubleshooting
# Only shown when LOG_LEVEL=DEBUG
log_debug() {
    _log "DEBUG" "${_CLR_DIM}" "$@"
}

# Info level - general operational messages
log_info() {
    _log "INFO" "${_CLR_BLUE}" "$@"
}

# Success level - operation completed successfully
# Same priority as INFO but with green color for visibility
log_success() {
    _log "SUCCESS" "${_CLR_GREEN}${_CLR_BOLD}" "$@"
}

# Warning level - potential issues that don't stop execution
log_warn() {
    _log "WARN" "${_CLR_YELLOW}" "$@"
}

# Error level - errors that may cause issues
log_error() {
    _log "ERROR" "${_CLR_RED}${_CLR_BOLD}" "$@"
}

# Fatal level - logs error and exits script
# Usage: log_fatal "message" [exit_code]
log_fatal() {
    local message="$1"
    local exit_code="${2:-1}"
    _log "ERROR" "${_CLR_RED}${_CLR_BOLD}" "FATAL: ${message}"
    exit "${exit_code}"
}

# ============================================================================
# Special Purpose Logging Functions
# ============================================================================

# Log sensitive information - ONLY to console, NEVER to file
# Use for debugging credentials, tokens, etc.
# Warning: Even console output can be captured in session logs!
log_sensitive() {
    local level="${1:-DEBUG}"
    shift
    local message="$*"

    # Only log if level threshold met
    if ! _should_log "$level"; then
        return 0
    fi

    local timestamp
    timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

    # Console only - never to file
    local console_msg="${_CLR_DIM}[${timestamp}]${_CLR_RESET} ${_CLR_YELLOW}[SENSITIVE]${_CLR_RESET} ${_CLR_CYAN}[${_LOG_SCRIPT_NAME}]${_CLR_RESET} ${message}"
    echo -e "${console_msg}" >&2
}

# Log a step in a multi-step process
# Usage: log_step 1 5 "Creating security group"
log_step() {
    local current="$1"
    local total="$2"
    shift 2
    local message="$*"
    log_info "Step ${current}/${total}: ${message}"
}

# Log a separator line for visual grouping
log_separator() {
    local char="${1:-=}"
    local width="${2:-60}"
    local line
    line=$(printf '%*s' "$width" '' | tr ' ' "$char")
    log_info "${line}"
}

# Log key-value pair (useful for configuration dumps)
# Usage: log_kv "Region" "us-east-1"
log_kv() {
    local key="$1"
    local value="$2"
    local padding="${3:-20}"
    local formatted_key
    formatted_key=$(printf "%-${padding}s" "${key}:")
    log_info "  ${formatted_key} ${value}"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Get current log level
get_log_level() {
    echo "${_LOG_LEVEL}"
}

# Set log level at runtime
set_log_level() {
    _LOG_LEVEL="${1^^}"
}

# Get log file path
get_log_file() {
    echo "${_LOG_FILE}"
}

# Check if debug logging is enabled
is_debug_enabled() {
    [[ "${_LOG_LEVEL^^}" == "DEBUG" ]]
}

# ============================================================================
# Auto-initialization
# ============================================================================

# Initialize with defaults (can be re-initialized with init_logger)
init_logger

