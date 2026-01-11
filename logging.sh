#!/usr/bin/env bash

# Simple logging helper for Bash scripts.
# Inspired by common practices and patterns 


# LOG_LEVEL controls which messages are emitted.
# Supported levels (in increasing severity): DEBUG, INFO, WARN, ERROR.
: "${LOG_LEVEL:=INFO}"

# Optional: write logs to a file. Default: <script-name>.log in the current directory.
_script_name="${SCRIPT_NAME_OVERRIDE:-$(basename "$0")}"
: "${LOG_FILE:="./${_script_name%.sh}.log"}"

_log_level_num() {
  # Map level name to a numeric value for comparison
  case "$1" in
    DEBUG) echo 10 ;;
    INFO)  echo 20 ;;
    WARN)  echo 30 ;;
    ERROR) echo 40 ;;
    *)     echo 20 ;; # default to INFO
  esac
}

_should_log() {
  local level="$1"
  local current_level="${LOG_LEVEL:-INFO}"
  [ "$(_log_level_num "$level")" -ge "$(_log_level_num "$current_level")" ]
}

_log() {
  local level="$1"; shift

  if ! _should_log "$level"; then
    return 0
  fi

  local timestamp
  timestamp="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"

  local msg="[$timestamp] [$level] [${_script_name}] $*"

  # Log to stderr so stdout can be used for structured/script output if needed
  >&2 echo "$msg"

  # Also append to a log file (best-effort; ignore errors)
  if [ -n "${LOG_FILE:-}" ]; then
    {
      echo "$msg"
    } >>"$LOG_FILE" 2>/dev/null || true
  fi
}

log_debug() { _log "DEBUG" "$@"; }
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }



