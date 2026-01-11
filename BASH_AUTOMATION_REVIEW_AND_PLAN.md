# Automate AWS Resource Creation with Bash — Deep Critique + Senior Plan (No Code)

This document reviews the current Bash codebase and proposes enhancements aligned to the grading rubric and “industry-standard” expectations. It includes a **Terraform-like state file approach**, a **cleanup strategy driven by state**, and an **orchestrator script design**. (Per request: **no code is included**; this is plain-English planning.)

---

## 1) Quick read of the current codebase (what you have today)

### What exists
- **Resource creators**
  - `create_ec2.sh`: creates/reuses a key pair, resolves latest Amazon Linux 2 AMI via SSM, launches one EC2 instance, waits until running, prints instance ID + public IP.
  - `create_security_group.sh`: creates/reuses a security group in default VPC, ensures ingress for ports 22 and 80, prints SG info JSON.
  - `create_s3_bucket.sh`: creates a uniquely named bucket, enables versioning, applies a **public-read** bucket policy, uploads `welcome.txt`, tags the bucket.
- **Cleanup**
  - `cleanup_resources.sh`: tries to terminate instances, delete key pairs (by name prefix), delete security groups (by tag), delete S3 buckets (by **name contains**).
- **Shared utility**
  - `logging.sh`: consistent log levels, timestamps, and file logging.

### Positive foundation (keep these)
- **`set -euo pipefail`** across scripts (good baseline discipline).
- **Parameterization via env vars** (region/profile/name overrides).
- **AMI resolution via SSM** rather than hardcoding AMI IDs (more robust).
- **Idempotent-ish behavior** in SG and key pair logic (reuse if exists).
- **Centralized logging helper** (rare in beginner Bash repos; good signal).

---

## 2) Rubric alignment: where points are likely gained/lost

Your grading weights:
- **Technical Accuracy (30%)**
- **Best Practices (25%)**
- **Documentation Quality (25%)**
- **Completeness (20%)**

### Technical Accuracy (30%) — risks that can fail a grader run
- **Tag inconsistency breaks cleanup**:
  - `cleanup_resources.sh` looks for `Project=AutomationLab`, but:
    - EC2 uses `Project=<TAG_NAME>` where the default `TAG_NAME` is `Automationlab-instance` (not `AutomationLab`).
    - Security group default tag value is `Automationlab` (different casing/value).
    - S3 tagging uses `Project=AutomationLab` (closer).
  - Outcome: cleanup may miss resources or delete the wrong ones.
- **Region env var bug in S3 script**:
  - `create_s3_bucket.sh` uses `AWS_DEFAULT` (not the typical `AWS_DEFAULT_REGION`). This can silently fall back to `us-east-1` when you didn’t intend to.
- **Cleanup assumes tools/paths that may not exist**:
  - Uses `/tmp/...` paths (not portable on Windows Git Bash).
  - Mentions `jq` but does not require/validate it. Also doesn’t actually use `jq` to delete versions; it uses `aws s3 rm --recursive` which does **not** fully clean versioned buckets.
  - Outcome: S3 deletion may fail due to remaining versions/delete markers.
- **EC2 created without the created security group**:
  - `create_ec2.sh` launches an instance but doesn’t attach the SG created by `create_security_group.sh`.
  - Outcome: ports may not be open, SSH may not work; “intended AWS operations” feel incomplete.

### Best Practices (25%) — where reviewers expect “senior” behavior
- **No shared conventions** across scripts for:
  - consistent naming/tagging strategy,
  - consistent validation (prereqs, aws identity, region),
  - consistent user-facing output format (human vs machine-readable),
  - consistent error handling and retries.
- **Secrets/credentials posture** not described:
  - Scripts rely on AWS CLI env/profile, but repo doesn’t clearly guide least-privilege IAM policy expectations.
- **Key pair + chmod on Windows**:
  - `chmod 600` is fine on Linux/macOS but can confuse Windows users; reviewers may run this on Windows and it won’t behave as expected.

### Documentation Quality (25%) — currently the biggest gap for easy points
- There’s no top-level `README.md` explaining:
  - prerequisites (AWS CLI, configured credentials, region, permissions),
  - what each script does,
  - how to run in correct order,
  - how to validate outcomes,
  - how to clean up safely,
  - common failure modes.
- The “why” is missing:
  - why SSM AMI parameter is used,
  - why bucket policy is public and what that implies,
  - what tags are authoritative.

### Completeness (20%)
- All scripts exist, but the “system” isn’t cohesive:
  - Missing orchestration (run in correct dependency order),
  - Cleanup reliability is questionable (S3 versioning, tag mismatch),
  - Lacks screenshots guidance/checklist.

---

## 3) Biggest design flaw today: you don’t have a “source of truth”

Terraform’s power comes from these properties:
- A **state file** that records exactly what was created (IDs, names, ARNs, region, dependencies).
- A reconciliation model (“what exists” vs “what I want”), even if minimal.

Your current approach is mostly:
- **Create**: “fire commands, print outputs.”
- **Destroy**: “best-effort filtering by tags/prefixes.”

This is where you lose points because:
- cleanup becomes probabilistic,
- multiple runs collide,
- drift is hard to reason about,
- graders can’t see discipline in lifecycle management.

---

## 4) Terraform-like state file design (practical for Bash)

### State goals
Your state should make these answers trivial:
- What resources were created in this run?
- In which region/account?
- What dependencies exist (e.g., EC2 uses SG and key pair)?
- What needs to be destroyed and in what order?
- Is this run “complete” or partially failed?

### Recommended state format (keep it simple)
- Use a **single JSON** file as the canonical state (easy for AWS CLI/JMESPath; also easy to inspect in reviews).
- Store state under a dedicated directory, e.g. `.state/`.
- Use one state per environment/workspace (dev/test), e.g. `.state/dev.json`.

### Minimum fields to capture
- **Metadata**
  - `state_version` (for future migrations)
  - `created_at`, `updated_at`
  - `workspace` (e.g., `dev`, `grader-run`)
  - `aws_account_id` (from `sts get-caller-identity`)
  - `region`
  - `profile` (if used)
- **Conventions**
  - `tags` (the authoritative tag set used everywhere)
  - `name_prefix` (single prefix for all names)
- **Resources**
  - `ec2`: instance id, key pair name, attached SG id(s), public IP, subnet/vpc, AMI ID used
  - `security_group`: sg id, vpc id, ingress rules you expect
  - `s3`: bucket name, region, versioning enabled, policy applied, object key(s) uploaded
- **Lifecycle tracking**
  - per-resource `status`: planned/created/failed/destroyed
  - error message/last action for debugging

### State write discipline (what seniors do)
- **Atomic writes**: write to a temp file then move/rename to avoid corruption.
- **Locking**: a lock file to prevent concurrent runs from clobbering the state.
- **Idempotency**: on rerun, decide whether to:
  - reuse resources recorded in state (preferred), or
  - detect drift and repair, or
  - create new resources under a new workspace.

### Two “modes” to support (for grading and real life)
- **Ephemeral mode (grader-friendly)**: each run creates a new workspace/state file (timestamped), then destroy uses that exact state file.
- **Stable workspace mode (team-friendly)**: one `dev` workspace that can be applied/destroyed repeatedly.

---

## 5) Cleanup redesign: “destroy by state” first, tags second

### Why your cleanup should be state-driven
Tags and prefixes are helpful but imperfect:
- Tags can be inconsistent (they already are).
- Prefix filters can delete the wrong thing.
- AWS resources can share names across runs.

### The cleanup algorithm (high-level, Terraform-ish)
- **Input**: state file path (explicit), plus region/profile.
- **Validate**:
  - Confirm account + region match what’s in state (prevent deleting in the wrong place).
  - Confirm state lock not held (or require `--force`).
- **Destroy in dependency order**:
  1. EC2 instance termination (and wait)
  2. Detach/delete related network dependencies if you created them (you don’t today)
  3. Security group deletion (only once no ENIs/instances depend on it)
  4. Key pair deletion (if created by your system, not user-provided)
  5. S3 bucket emptying (including **versions + delete markers**) then bucket deletion
- **Update state** as you destroy each component (mark destroyed).

### When tags are still useful
Use tags as:
- **A safety net**: verify that the resource you’re about to delete has the expected tag(s).
- **A discovery tool** for “orphan cleanup”:
  - e.g., if state is missing/corrupt, you can provide a separate “sweep” mode that cleans everything with `Project=AutomationLab` (with very explicit warnings).

### Safety rails seniors add
- **“Plan” output** for destroy: list what will be deleted before doing it.
- **Confirmation gate** unless `--auto-approve` is supplied.
- **Explicit state selection**: require `--state <file>` for destroy to prevent accidental global deletion.

---

## 6) Orchestrator script design (industry standard for Bash-based infra)

### The problem it solves
Right now, scripts are independent, so:
- ordering isn’t enforced,
- shared config isn’t centralized,
- state isn’t unified,
- output is inconsistent.

### What the orchestrator should do

