# Strategic Implementation Plan: AWS Resource Automation with Bash

> **Document Purpose**: This plan provides a systematic approach to refactoring the codebase to achieve maximum rubric scores while adhering to industry-standard practices, DRY/SOLID principles, and robust edge-case handling.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current State Analysis](#2-current-state-analysis)
3. [Rubric-Aligned Prioritization Matrix](#3-rubric-aligned-prioritization-matrix)
4. [Architecture Redesign](#4-architecture-redesign)
5. [Detailed Implementation Phases](#5-detailed-implementation-phases)
6. [Edge Cases & Error Handling Strategy](#6-edge-cases--error-handling-strategy)
7. [Testing & Validation Strategy](#7-testing--validation-strategy)
8. [File-by-File Changes](#8-file-by-file-changes)
9. [New Files to Create](#9-new-files-to-create)
10. [Documentation Plan](#10-documentation-plan)
11. [Implementation Checklist](#11-implementation-checklist)

---

## 1. Executive Summary

### Current Score Estimate (Pre-Refactor)

| Criterion              | Weight | Est. Score | Est. Points | Risk Areas                        |
|------------------------|--------|------------|-------------|-----------------------------------|
| Technical Accuracy     | 30%    | 60-70%     | 18-21/30    | Tag mismatch, SG not attached     |
| Best Practices         | 25%    | 50-60%     | 12-15/25    | Inconsistencies, no DRY, no state |
| Documentation Quality  | 25%    | 20-30%     | 5-7.5/25    | No README, sparse inline docs     |
| Completeness           | 20%    | 70-80%     | 14-16/20    | All scripts exist, cleanup weak   |
| **Estimated Total**    | 100%   | ~55%       | ~55/100     |                                   |

### Target Score (Post-Refactor)

| Criterion              | Weight | Target     | Target Pts  | Key Improvements                  |
|------------------------|--------|------------|-------------|-----------------------------------|
| Technical Accuracy     | 30%    | 95-100%    | 28-30/30    | All bugs fixed, verified runs     |
| Best Practices         | 25%    | 90-95%     | 22-24/25    | DRY, state file, consistent APIs  |
| Documentation Quality  | 25%    | 95-100%    | 24-25/25    | Comprehensive README + inline     |
| Completeness           | 20%    | 100%       | 20/20       | All scripts + screenshots guide   |
| **Target Total**       | 100%   | ~94%       | ~94/100     |                                   |

---

## 2. Current State Analysis

### 2.1 Critical Bugs (Technical Accuracy - 30%)

#### BUG-001: Tag Inconsistency (CRITICAL)
```
Location: All scripts
Impact: Cleanup fails to find/delete resources correctly

Current Values:
├── create_ec2.sh:           TAG_NAME="Automationlab-instance" (Project=Automationlab-instance)
├── create_security_group.sh: TAG_VALUE="Automationlab"        (Project=Automationlab)
├── create_s3_bucket.sh:      TAG_VALUE="AutomationLab"        (Project=AutomationLab)
└── cleanup_resources.sh:     TAG_VALUE="AutomationLab"        (looks for Project=AutomationLab)

Result: EC2 instances and Security Groups will NOT be cleaned up!
```

#### BUG-002: Region Environment Variable Typo (HIGH)
```
Location: create_s3_bucket.sh, line 17
Current:  REGION="${AWS_REGION:-${AWS_DEFAULT:-us-east-1}}"
Expected: REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

Impact: AWS_DEFAULT_REGION is ignored; buckets may be created in wrong region
```

#### BUG-003: EC2 Not Attached to Security Group (CRITICAL)
```
Location: create_ec2.sh
Issue: run-instances does not include --security-group-ids parameter
Impact: Instance uses default VPC security group, not the custom one created
        SSH/HTTP ports may not be accessible as expected
```

#### BUG-004: S3 Versioned Object Cleanup Fails (HIGH)
```
Location: cleanup_resources.sh, lines 61-66
Issue: Uses `aws s3 rm --recursive` which does NOT delete object versions
       The jq command exists but doesn't actually delete anything

Impact: Versioned buckets cannot be deleted (DeleteBucketError)
```

#### BUG-005: Cleanup Uses Wrong Filter for S3 (MEDIUM)
```
Location: cleanup_resources.sh, line 56
Current: Filters by bucket name containing "automationlab-bucket"
Expected: Should filter by tag (Project=AutomationLab) for consistency
```

### 2.2 Best Practices Violations (25%)

#### DRY Violations

| Issue | Locations | Description |
|-------|-----------|-------------|
| Repeated AWS CLI wrapper | All 4 scripts | Each script defines its own `awscli()` or `aws_cli()` function |
| Repeated prerequisite checks | All 4 scripts | `command -v aws` check duplicated everywhere |
| Repeated region/profile setup | All 4 scripts | Same pattern with different variable sources |
| Repeated logging source | All 4 scripts | Same 3-line pattern to source logging.sh |

#### SOLID Violations (adapted for Bash)

| Principle | Issue | Impact |
|-----------|-------|--------|
| Single Responsibility | `cleanup_resources.sh` handles 4 resource types | Hard to test, modify, maintain |
| Open/Closed | No plugin/hook mechanism | Adding new resource types requires modifying core scripts |
| Interface Segregation | No common interface contract | Scripts behave inconsistently |
| Dependency Inversion | Scripts hardcode behavior | No configuration abstraction layer |

#### Inconsistencies

| Area | Variations Found |
|------|------------------|
| AWS CLI wrapper naming | `awscli()` vs `aws_cli()` |
| Tag key for project | `TAG_KEY="Project"` vs `TAG_KEY="tag:Project"` |
| Log file location | Some use `./`, cleanup has no logging |
| Error messages | Different formats, some missing |

### 2.3 Documentation Gaps (25%)

- ❌ No `README.md` exists
- ❌ No prerequisites documentation
- ❌ No usage instructions
- ❌ No expected IAM permissions documented
- ❌ No troubleshooting guide
- ❌ No architecture diagram description
- ⚠️ Inline comments exist but are sparse
- ⚠️ No explanation of design decisions (e.g., why SSM for AMI)

### 2.4 Completeness Issues (20%)

- ✅ All required scripts exist
- ✅ Cleanup script exists (optional but present)
- ❌ No orchestrator to run scripts in correct order
- ❌ No verification/validation script
- ❌ Screenshots guidance missing
- ❌ State tracking for reliable cleanup missing

---

## 3. Rubric-Aligned Prioritization Matrix

### Priority 1: Critical Path (Must Fix First)

| Task | Rubric Impact | Effort | Priority Score |
|------|--------------|--------|----------------|
| Fix tag consistency | Tech Accuracy +10% | Low | P1-CRITICAL |
| Attach SG to EC2 | Tech Accuracy +8% | Low | P1-CRITICAL |
| Fix region variable | Tech Accuracy +2% | Trivial | P1-CRITICAL |
| Fix S3 version cleanup | Tech Accuracy +5% | Medium | P1-HIGH |

### Priority 2: Structure & DRY (Best Practices Score)

| Task | Rubric Impact | Effort | Priority Score |
|------|--------------|--------|----------------|
| Create common.sh library | Best Practices +8% | Medium | P2-HIGH |
| Implement state file | Best Practices +5% | Medium | P2-HIGH |
| Standardize all scripts | Best Practices +7% | Medium | P2-HIGH |
| Add input validation | Best Practices +3% | Low | P2-MEDIUM |

### Priority 3: Documentation (25% of grade!)

| Task | Rubric Impact | Effort | Priority Score |
|------|--------------|--------|----------------|
| Write comprehensive README | Documentation +20% | Medium | P3-CRITICAL |
| Add inline documentation | Documentation +5% | Low | P3-HIGH |
| Create screenshots guide | Completeness +3% | Low | P3-MEDIUM |

### Priority 4: Polish & Edge Cases

| Task | Rubric Impact | Effort | Priority Score |
|------|--------------|--------|----------------|
| Create orchestrator | Completeness +5% | Medium | P4-MEDIUM |
| Add verification script | Completeness +2% | Low | P4-LOW |
| Windows compatibility | Best Practices +2% | Low | P4-LOW |

---

## 4. Architecture Redesign

### 4.1 Proposed Directory Structure

```
AutomateAwsResource/
├── README.md                    # Comprehensive documentation (NEW)
├── config.env                   # Centralized configuration (NEW)
├── orchestrate.sh               # Main entry point (NEW)
│
├── lib/                         # Shared libraries (NEW)
│   ├── common.sh                # DRY: shared functions
│   ├── logging.sh               # Enhanced logging (MOVE & ENHANCE)
│   ├── state.sh                 # State file management (NEW)
│   └── validation.sh            # Prerequisites & input validation (NEW)
│
├── scripts/                     # Resource scripts (REORGANIZE)
│   ├── create_ec2.sh            # EC2 creation (REFACTOR)
│   ├── create_security_group.sh # SG creation (REFACTOR)
│   ├── create_s3_bucket.sh      # S3 creation (REFACTOR)
│   └── cleanup_resources.sh     # Cleanup (REFACTOR)
│
├── .state/                      # State files (NEW, gitignored)
│   └── *.json                   # Per-workspace state
│
├── docs/                        # Additional documentation (NEW)
│   └── SCREENSHOTS_GUIDE.md     # How to capture screenshots
│
└── .gitignore                   # Ignore sensitive files (NEW/UPDATE)
```

### 4.2 State File Schema

```json
{
  "schema_version": "1.0",
  "metadata": {
    "workspace": "dev",
    "created_at": "2026-01-08T10:00:00Z",
    "updated_at": "2026-01-08T10:05:00Z",
    "aws_account_id": "123456789012",
    "aws_region": "us-east-1",
    "aws_profile": "default"
  },
  "config": {
    "project_tag": "AutomationLab",
    "name_prefix": "automationlab"
  },
  "resources": {
    "key_pair": {
      "name": "automationlab-key",
      "status": "created",
      "created_at": "2026-01-08T10:01:00Z"
    },
    "security_group": {
      "id": "sg-0123456789abcdef0",
      "name": "automationlab-sg",
      "vpc_id": "vpc-abcdef01",
      "status": "created",
      "created_at": "2026-01-08T10:02:00Z"
    },
    "ec2_instance": {
      "id": "i-0123456789abcdef0",
      "public_ip": "1.2.3.4",
      "ami_id": "ami-0123456789abcdef0",
      "key_pair": "automationlab-key",
      "security_group_id": "sg-0123456789abcdef0",
      "status": "created",
      "created_at": "2026-01-08T10:03:00Z"
    },
    "s3_bucket": {
      "name": "automationlab-bucket-1704700800",
      "region": "us-east-1",
      "versioning": true,
      "objects": ["welcome.txt"],
      "status": "created",
      "created_at": "2026-01-08T10:04:00Z"
    }
  }
}
```

### 4.3 Common Library Design (`lib/common.sh`)

```
Purpose: Single source of truth for shared functionality

Responsibilities:
├── Configuration loading (from config.env)
├── AWS CLI wrapper with consistent region/profile handling
├── Prerequisite validation (aws cli, jq, region, credentials)
├── Tag management (single authoritative PROJECT_TAG)
├── Retry logic for transient AWS errors
├── Cross-platform compatibility helpers
└── Script initialization boilerplate
```

### 4.4 Execution Flow Diagram

```
orchestrate.sh
    │
    ├── [1] Load config.env
    ├── [2] Initialize state file (if not exists)
    ├── [3] Validate prerequisites
    │
    ├── [4] create_security_group.sh ────────────┐
    │         └── Outputs: SG_ID                 │
    │                                            │ State file
    ├── [5] create_ec2.sh ◄──────────────────────┤ updated after
    │         └── Uses: SG_ID from state         │ each step
    │         └── Outputs: INSTANCE_ID, IP       │
    │                                            │
    ├── [6] create_s3_bucket.sh ─────────────────┘
    │         └── Outputs: BUCKET_NAME
    │
    └── [7] Print summary + save final state
```

---

## 5. Detailed Implementation Phases

### Phase 1: Foundation (Day 1)

#### 1.1 Create Configuration File (`config.env`)

```bash
# Centralized configuration - single source of truth
# All scripts source this file for consistent behavior

# AWS Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-default}"

# Naming Conventions (single prefix for all resources)
NAME_PREFIX="automationlab"

# Authoritative Tags (CRITICAL: must be consistent everywhere)
PROJECT_TAG="AutomationLab"
TAG_KEY="Project"

# Resource-Specific Defaults
KEY_NAME="${NAME_PREFIX}-key"
SECURITY_GROUP_NAME="${NAME_PREFIX}-sg"
BUCKET_PREFIX="${NAME_PREFIX}-bucket"
INSTANCE_TYPE="t2.micro"

# Behavior Flags
AUTO_APPROVE="${AUTO_APPROVE:-false}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

# State Management
STATE_DIR=".state"
STATE_FILE="${STATE_DIR}/current.json"
```

#### 1.2 Create Common Library (`lib/common.sh`)

Key functions to implement:

| Function | Purpose |
|----------|---------|
| `load_config()` | Source config.env with validation |
| `init_script()` | Standard initialization (source config, logging, validate) |
| `aws_cmd()` | Unified AWS CLI wrapper with retry logic |
| `check_prerequisites()` | Verify aws cli, credentials, region |
| `validate_aws_identity()` | Confirm we're in expected account |
| `get_default_vpc()` | Reusable VPC lookup |
| `apply_tags()` | Consistent tagging across resources |
| `retry_command()` | Exponential backoff for transient errors |
| `is_windows()` | Platform detection for compatibility |
| `safe_chmod()` | Cross-platform permission handling |

#### 1.3 Enhance Logging (`lib/logging.sh`)

Enhancements needed:

| Feature | Current | Enhanced |
|---------|---------|----------|
| Log rotation | ❌ | ✅ Max file size check |
| Structured output | ❌ | ✅ JSON option for machine parsing |
| Color coding | ❌ | ✅ Terminal color support (optional) |
| Caller info | ❌ | ✅ Function name + line number |
| Log to state | ❌ | ✅ Operation logs in state file |

### Phase 2: Fix Critical Bugs (Day 1-2)

#### 2.1 Standardize Tags Across All Scripts

**Before (inconsistent):**
```bash
# create_ec2.sh
TAG_NAME="${TAG_NAME:-Automationlab-instance}"  # Wrong!

# create_security_group.sh
TAG_VALUE="${TAG_VALUE:-Automationlab}"  # Wrong!

# create_s3_bucket.sh
TAG_VALUE="${TAG_VALUE:-AutomationLab}"  # Correct but isolated
```

**After (unified via config.env):**
```bash
# All scripts use:
source "${SCRIPT_DIR}/lib/common.sh"
# Which loads config.env with:
PROJECT_TAG="AutomationLab"  # Single source of truth
```

#### 2.2 Attach Security Group to EC2

**Add to create_ec2.sh:**
```
Before run-instances:
1. Read SG_ID from state file (or environment)
2. Validate SG exists in current region
3. Add --security-group-ids "$SG_ID" to run-instances

Dependencies:
- Requires state.sh library
- Requires security group to be created first (orchestrator handles order)
```

#### 2.3 Fix S3 Version Cleanup

**Replace current approach with proper version deletion:**
```
Algorithm:
1. List all object versions (aws s3api list-object-versions)
2. Delete all versions in batches (aws s3api delete-objects)
3. Delete all delete markers in batches
4. Then delete the empty bucket

Handle edge cases:
- Bucket doesn't exist → graceful skip
- Bucket in different region → use correct endpoint
- Thousands of versions → paginate properly
```

### Phase 3: DRY Refactoring (Day 2-3)

#### 3.1 Refactor Each Script to Use Common Library

**Standard script template:**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Script identity
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common library (handles everything)
source "${SCRIPT_DIR}/../lib/common.sh"

# Initialize (validates prerequisites, loads config, sets up logging)
init_script

# Script-specific logic here...
```

#### 3.2 State File Operations (`lib/state.sh`)

| Function | Purpose |
|----------|---------|
| `state_init()` | Create state file if not exists |
| `state_read()` | Read entire state or specific path |
| `state_write()` | Update state with atomic write |
| `state_get_resource()` | Get specific resource by type |
| `state_set_resource()` | Set resource with status |
| `state_lock()` | Prevent concurrent modifications |
| `state_unlock()` | Release lock |

### Phase 4: Orchestrator & Cleanup Redesign (Day 3-4)

#### 4.1 Orchestrator Script Design

**Command interface:**
```bash
./orchestrate.sh [command] [options]

Commands:
  apply     Create all resources (default)
  destroy   Clean up all resources
  plan      Show what would be created/destroyed (dry-run)
  status    Show current state
  verify    Validate created resources are accessible

Options:
  --workspace NAME    Use named workspace (default: current)
  --auto-approve      Skip confirmation prompts
  --verbose          Enable debug logging
  --state FILE       Use specific state file
```

#### 4.2 Cleanup Redesign Strategy

**Two-tier cleanup approach:**

```
Tier 1: State-Driven Cleanup (Primary)
├── Read state file
├── Verify account/region match
├── Delete in reverse dependency order:
│   ├── 1. S3 bucket (empty all versions first)
│   ├── 2. EC2 instance (wait for termination)
│   ├── 3. Security group (wait for ENI detachment)
│   └── 4. Key pair
├── Update state as each resource is deleted
└── Final state shows all resources as "destroyed"

Tier 2: Tag-Based Sweep (Fallback/Safety Net)
├── Only used when state is missing/corrupt
├── Requires explicit --sweep flag
├── Warns user and requires confirmation
├── Searches for resources with Project=AutomationLab tag
└── Deletes with same dependency order
```

### Phase 5: Documentation (Day 4)

See [Section 10: Documentation Plan](#10-documentation-plan) for full details.

---

## 6. Edge Cases & Error Handling Strategy

### 6.1 AWS API Edge Cases

| Scenario | Detection | Handling |
|----------|-----------|----------|
| Rate limiting (throttling) | Error code `Throttling` | Exponential backoff retry (3 attempts) |
| Resource already exists | Error code `*AlreadyExists` | Log as info, reuse existing, continue |
| Resource not found | Error code `*NotFound` | Context-dependent: error or skip |
| Insufficient permissions | Error code `*Unauthorized` | Log clear error, exit with helpful message |
| Region not enabled | Error code `*RegionDisabled` | Exit with instructions to enable region |
| Service quota exceeded | Error code `*LimitExceeded` | Exit with quota increase instructions |
| Network timeout | Connection errors | Retry up to 3 times with backoff |
| Invalid credentials | `ExpiredToken`, `InvalidClientTokenId` | Exit with credential refresh instructions |

### 6.2 Input Validation Edge Cases

| Input | Validation | Error Handling |
|-------|------------|----------------|
| Bucket name | S3 naming rules (lowercase, 3-63 chars, no underscores) | Transform or reject with clear message |
| Key pair name | AWS naming rules | Validate before API call |
| Region | Must be valid AWS region | Validate against known list |
| Instance type | Must be valid and available in region | Query or validate |
| Empty environment variables | Detect empty strings vs unset | Use defaults with logging |

### 6.3 State File Edge Cases

| Scenario | Detection | Handling |
|----------|-----------|----------|
| State file missing | File not exists check | Create new state or error if destroy |
| State file corrupted | JSON parse failure | Backup and create new, warn user |
| Concurrent access | Lock file exists | Wait with timeout, then error |
| State/reality drift | Resource IDs in state don't exist | Mark as stale, offer sweep |
| Partial creation failure | Status shows "creating" | Cleanup partial resources |

### 6.4 Platform Compatibility Edge Cases

| Platform | Issue | Solution |
|----------|-------|----------|
| Windows Git Bash | `chmod 600` doesn't work | Skip chmod on Windows, document SSH agent use |
| Windows Git Bash | `/tmp/` path issues | Use `${TMPDIR:-/tmp}` or `mktemp` |
| Windows PowerShell | Different shell semantics | Document Git Bash requirement |
| macOS | BSD `date` different from GNU | Use portable date formats |
| Linux | May have older bash | Require bash 4.0+, validate on startup |

### 6.5 Network Edge Cases

| Scenario | Detection | Handling |
|----------|-----------|----------|
| No internet | AWS commands timeout | Detect early, fail fast with message |
| Slow network | Commands taking long | Show progress indicators |
| Partial upload | S3 upload interrupted | Verify object exists with checksum |

---

## 7. Testing & Validation Strategy

### 7.1 Pre-Submission Validation Checklist

```bash
# Run this before submission to verify everything works

# 1. Fresh environment test
unset AWS_REGION AWS_PROFILE AWS_DEFAULT_REGION
export AWS_REGION="us-east-1"
export AWS_PROFILE="your-profile"

# 2. Prerequisite check
./orchestrate.sh status

# 3. Create resources
./orchestrate.sh apply --auto-approve

# 4. Verify resources (captures screenshot-worthy output)
./orchestrate.sh verify

# 5. Cleanup
./orchestrate.sh destroy --auto-approve

# 6. Verify cleanup
./orchestrate.sh status  # Should show no resources
```

### 7.2 What Screenshots Should Show

| Screenshot | Purpose | How to Capture |
|------------|---------|----------------|
| `aws configure list` | Prove CLI is configured | Terminal command |
| `aws sts get-caller-identity` | Prove credentials work | Terminal command |
| `./orchestrate.sh apply` output | Show successful creation | Terminal with scroll |
| AWS Console - EC2 | Visual confirmation | Browser screenshot |
| AWS Console - Security Groups | Show rules configured | Browser screenshot |
| AWS Console - S3 bucket | Show versioning, files | Browser screenshot |
| `./orchestrate.sh destroy` output | Show successful cleanup | Terminal |

---

## 8. File-by-File Changes

### 8.1 `logging.sh` → `lib/logging.sh`

| Line(s) | Change Type | Description |
|---------|-------------|-------------|
| 1-10 | Enhance | Add header comment with usage documentation |
| 15-24 | Keep | Log level mapping (works well) |
| 26-30 | Keep | `_should_log` function (good) |
| 32-52 | Enhance | Add color support, caller info, structured output option |
| 54-58 | Keep | Log level functions (good) |
| NEW | Add | `log_success()` function for green success messages |
| NEW | Add | `log_step()` function for progress steps |
| NEW | Add | `log_fatal()` function that logs and exits |

### 8.2 `create_ec2.sh` → `scripts/create_ec2.sh`

| Line(s) | Change Type | Description |
|---------|-------------|-------------|
| 1-13 | Replace | Use new common.sh sourcing pattern |
| 17-24 | Remove | Move to config.env |
| 27-29 | Remove | Use `aws_cmd()` from common.sh |
| 31-35 | Remove | Prereq check moves to common.sh |
| 40-50 | Enhance | Add state file update after key pair creation |
| 65-72 | Fix | **Add --security-group-ids parameter** |
| 70 | Fix | **Use consistent PROJECT_TAG** |
| 83-87 | Enhance | Add state file update with public IP |
| NEW | Add | State update at end of script |

### 8.3 `create_security_group.sh` → `scripts/create_security_group.sh`

| Line(s) | Change Type | Description |
|---------|-------------|-------------|
| 1-14 | Replace | Use new common.sh sourcing pattern |
| 18-25 | Remove | Move to config.env |
| 28 | Remove | Use `aws_cmd()` from common.sh |
| 25 | Fix | **Use PROJECT_TAG from config** |
| 39-50 | Keep | VPC resolution (good, move to common.sh) |
| 72-73 | Enhance | Use `apply_tags()` from common.sh |
| NEW | Add | State file update with SG_ID |
| NEW | Add | Output SG_ID for orchestrator to capture |

### 8.4 `create_s3_bucket.sh` → `scripts/create_s3_bucket.sh`

| Line(s) | Change Type | Description |
|---------|-------------|-------------|
| 1-13 | Replace | Use new common.sh sourcing pattern |
| 17 | Fix | **AWS_DEFAULT → AWS_DEFAULT_REGION** |
| 17-23 | Remove | Move to config.env |
| 25 | Remove | Use `aws_cmd()` from common.sh |
| 47-60 | Refactor | Move policy to separate function or template |
| 63 | Keep | Warning about public policy (good practice!) |
| 67-71 | Enhance | Verify upload succeeded |
| NEW | Add | State file update with bucket details |

### 8.5 `cleanup_resources.sh` → `scripts/cleanup_resources.sh`

| Line(s) | Change Type | Description |
|---------|-------------|-------------|
| 1-9 | Replace | Use new common.sh sourcing pattern |
| 12-15 | Remove | Prereq check moves to common.sh |
| 7-8 | Fix | **Use consistent tag filtering** |
| 19-28 | Enhance | Read from state file first, fall back to tag filter |
| 43-53 | Refactor | **Wait for EC2 termination before SG deletion** |
| 55-71 | Rewrite | **Implement proper versioned bucket deletion** |
| NEW | Add | Plan mode (show what would be deleted) |
| NEW | Add | Confirmation prompt unless --auto-approve |
| NEW | Add | Update state file after each deletion |

---

## 9. New Files to Create

### 9.1 `config.env`

**Purpose**: Single source of truth for all configuration
**Priority**: P1-CRITICAL
**Estimated lines**: ~30

### 9.2 `lib/common.sh`

**Purpose**: DRY - all shared functions
**Priority**: P2-HIGH
**Estimated lines**: ~150-200

**Key functions:**
- `init_script()` - Standard initialization
- `aws_cmd()` - AWS CLI wrapper with retry
- `check_prerequisites()` - Validate environment
- `get_default_vpc()` - Reusable VPC lookup
- `apply_tags()` - Consistent tagging
- `retry_command()` - Retry with backoff
- `cleanup_on_error()` - Trap handler for partial failures

### 9.3 `lib/state.sh`

**Purpose**: State file management
**Priority**: P2-HIGH
**Estimated lines**: ~100-150

**Key functions:**
- `state_init()` - Initialize state file
- `state_read()` - Read from state
- `state_write()` - Atomic write to state
- `state_get_resource()` - Get resource by type
- `state_set_resource()` - Set resource status
- `state_lock()` / `state_unlock()` - Concurrent access protection

### 9.4 `lib/validation.sh`

**Purpose**: Input and prerequisite validation
**Priority**: P2-MEDIUM
**Estimated lines**: ~80-100

**Key functions:**
- `validate_bucket_name()` - S3 naming rules
- `validate_region()` - Valid AWS region
- `validate_instance_type()` - Valid EC2 type
- `validate_aws_credentials()` - Credentials work
- `validate_required_permissions()` - IAM check

### 9.5 `orchestrate.sh`

**Purpose**: Main entry point for all operations
**Priority**: P4-MEDIUM
**Estimated lines**: ~200

**Commands:**
- `apply` - Create all resources
- `destroy` - Delete all resources
- `plan` - Dry run
- `status` - Show state
- `verify` - Validate resources

### 9.6 `README.md`

**Purpose**: Comprehensive documentation (25% of grade!)
**Priority**: P3-CRITICAL
**Estimated lines**: ~300-400

See [Section 10: Documentation Plan](#10-documentation-plan)

### 9.7 `.gitignore`

**Purpose**: Ignore sensitive/generated files
**Priority**: P2-LOW
**Estimated lines**: ~20

```gitignore
# State files (contain resource IDs, account info)
.state/

# Key pair files (NEVER commit!)
*.pem

# Log files
*.log

# Temporary files
*.tmp
*.bak

# OS files
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/
```

### 9.8 `docs/SCREENSHOTS_GUIDE.md`

**Purpose**: Help graders understand what to screenshot
**Priority**: P3-LOW
**Estimated lines**: ~50

---

## 10. Documentation Plan

### 10.1 README.md Structure

```markdown
# Automate AWS Resource Creation with Bash

## Overview
Brief description of what this project does.

## Architecture
- Diagram or description of script relationships
- State file explanation
- Dependency order

## Prerequisites
- AWS CLI installation
- Credentials configuration  
- Required IAM permissions (specific policy!)
- Supported platforms

## Quick Start
1. Clone repository
2. Configure credentials
3. Run orchestrator
4. Verify resources
5. Cleanup

## Configuration
- Environment variables
- config.env explanation
- Customization options

## Usage

### Create Resources
./orchestrate.sh apply

### Verify Resources
./orchestrate.sh verify

### Cleanup Resources
./orchestrate.sh destroy

### Check Status
./orchestrate.sh status

## Script Details
- create_ec2.sh: What it does, inputs, outputs
- create_security_group.sh: What it does, inputs, outputs
- create_s3_bucket.sh: What it does, inputs, outputs
- cleanup_resources.sh: What it does, inputs, outputs

## Design Decisions
- Why SSM for AMI lookup
- Why state file approach
- Why tag-based organization
- Public bucket policy warning

## Troubleshooting
- Common errors and solutions
- Permission issues
- Region issues
- Credential issues

## Security Considerations
- IAM least privilege
- Key pair handling
- Public S3 bucket warning

## Contributing
How to modify/extend

## License
```

### 10.2 Inline Documentation Standards

Every script should have:

```bash
#!/usr/bin/env bash
#
# Script Name: create_ec2.sh
# Description: Creates an EC2 instance with proper tagging and security group attachment
# 
# Dependencies:
#   - AWS CLI v2
#   - jq (optional, for JSON parsing)
#   - lib/common.sh
#   - Security group must exist (created by create_security_group.sh)
#
# Environment Variables:
#   AWS_REGION      - Target region (default: us-east-1)
#   AWS_PROFILE     - AWS CLI profile (default: default)
#   INSTANCE_TYPE   - EC2 instance type (default: t2.micro)
#   KEY_NAME        - Name for SSH key pair (default: automationlab-key)
#
# Outputs:
#   - Creates EC2 instance with Project=AutomationLab tag
#   - Saves private key to ./automationlab-key.pem
#   - Updates .state/current.json with instance details
#   - Prints instance ID and public IP to stdout
#
# Exit Codes:
#   0 - Success
#   1 - Prerequisites not met
#   2 - AWS API error
#   3 - State file error
#
# Example:
#   AWS_REGION=us-west-2 ./create_ec2.sh
#
```

---

## 11. Implementation Checklist

### Phase 1: Foundation ⬜

- [ ] Create `lib/` directory
- [ ] Create `scripts/` directory  
- [ ] Create `config.env` with all defaults
- [ ] Create `lib/common.sh` with core functions
- [ ] Create `lib/state.sh` with state management
- [ ] Enhance `lib/logging.sh` with new features
- [ ] Create `.gitignore`

### Phase 2: Bug Fixes ⬜

- [ ] Fix tag consistency (use PROJECT_TAG everywhere)
- [ ] Fix AWS_DEFAULT → AWS_DEFAULT_REGION in S3 script
- [ ] Add --security-group-ids to EC2 creation
- [ ] Implement proper S3 versioned object deletion

### Phase 3: Script Refactoring ⬜

- [ ] Refactor `create_security_group.sh` to use common.sh
- [ ] Refactor `create_ec2.sh` to use common.sh + attach SG
- [ ] Refactor `create_s3_bucket.sh` to use common.sh
- [ ] Rewrite `cleanup_resources.sh` with state-driven approach

### Phase 4: Orchestration ⬜

- [ ] Create `orchestrate.sh` with apply/destroy/plan/status/verify
- [ ] Implement confirmation prompts
- [ ] Add --auto-approve flag
- [ ] Add --dry-run flag

### Phase 5: Documentation ⬜

- [ ] Write comprehensive `README.md`
- [ ] Add inline documentation to all scripts
- [ ] Create `docs/SCREENSHOTS_GUIDE.md`
- [ ] Add IAM policy documentation

### Phase 6: Testing & Polish ⬜

- [ ] Test fresh environment creation
- [ ] Test cleanup works completely  
- [ ] Test idempotency (run twice)
- [ ] Test error recovery
- [ ] Capture screenshots
- [ ] Final README review

---

## Summary: Key Principles to Follow

### DRY (Don't Repeat Yourself)
- Single `config.env` for all configuration
- Single `common.sh` for all shared functions
- Single `state.sh` for all state operations
- Single `PROJECT_TAG` value used everywhere

### SOLID (adapted for Bash)
- **S**ingle Responsibility: Each script does one thing
- **O**pen/Closed: Extensible via config, not code changes
- **L**iskov Substitution: N/A for Bash
- **I**nterface Segregation: Clean function APIs
- **D**ependency Inversion: Config drives behavior

### Industry Standards
- Atomic state file writes
- Lock files for concurrent access
- Exponential backoff for retries
- Structured logging with levels
- Exit codes with clear meaning
- Trap handlers for cleanup on failure

### Edge Case Handling
- Validate all inputs before API calls
- Handle all AWS API error codes gracefully
- Detect and handle platform differences
- Provide clear, actionable error messages

---

**Next Steps**: Begin implementation with Phase 1 (Foundation), then proceed sequentially through each phase. Each phase builds on the previous one, so the order is important.

