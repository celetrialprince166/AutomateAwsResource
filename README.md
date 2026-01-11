 # AWS Infrastructure Automation with Bash

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![AWS](https://img.shields.io/badge/Cloud-AWS-232F3E?style=for-the-badge&logo=amazon-aws&logoColor=white)
![Status](https://img.shields.io/badge/Status-Production%20Ready-success?style=for-the-badge)

A robust, idempotent, and state-aware automation suite for provisioning AWS resources (EC2, Security Groups, S3). This project implements **Infrastructure as Code (IaC)** principles using pure Bash, featuring Terraform-like state management, atomic locking, and industry-standard logging.

---

## 📖 Table of Contents
- [Architecture](#-architecture)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Key Features](#-key-features)
- [Configuration](#-configuration)
- [Project Structure](#-project-structure)

---

## 🏗 Architecture

This system uses an **Orchestrator Pattern** to manage dependencies and a **JSON State File** to track resources.

![Architecture Diagram](screenshots/orgestrateflow.png)




### Resource Dependency Flow
1.  **Security Group**: Created first to allow SSH (22) and HTTP (80).
2.  **EC2 Instance**: Launched using the Security Group ID and a generated Key Pair.
3.  **S3 Bucket**: Provisioned with versioning enabled and public-read access.

---

## 🛠 Prerequisites

Ensure you have the following installed:

*   **AWS CLI v2**: Configured with valid credentials (`aws configure`).
*   **Bash**: Version 4.0 or higher.
*   **jq** (Recommended): For robust JSON parsing (scripts include fallbacks if missing).

### Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd AutomateAwsResource

# Make scripts executable
chmod +x orchestrate.sh scripts/*.sh
```

---

## 🚀 Quick Start

The system is controlled via the `orchestrate.sh` entry point.

### 1. Provision Resources (`apply`)
Creates all resources in the correct dependency order.

```bash
./orchestrate.sh apply
```

**Expected Output:**

![Apply Command Output](screenshots/orgapplyoutput.png)

**Success Output:**

![Apply Success](screenshots/orgapplysuccess.png)

### 2. Check Status
View currently tracked resources in the state file.

```bash
./orchestrate.sh status
```

### 3. Cleanup (`destroy`)
Reliably destroys resources in reverse dependency order (S3 -> EC2 -> SG).

```bash
./orchestrate.sh destroy
```

**Expected Output:**

![Destroy Command Output](screenshots/orgdestroyoutput.png)

---

## 💎 Key Features

### 1. Terraform-like State Management
Unlike typical Bash scripts that "fire and forget," this project maintains a local state file (`.state/default.json`).
*   **Benefits**: Allows accurate cleanup and prevents "orphaned" resources.
*   **Implementation**: `lib/state.sh` uses atomic writes and file locking.

### 2. Idempotency
Run `apply` as many times as you want. The scripts check the state and AWS API before creating resources.
*   *If a Security Group exists, it uses it.*
*   *If an EC2 instance is running, it doesn't create a duplicate.*

### 3. Robust Error Handling
*   **Trap Handlers**: If the script fails mid-execution, a `trap` catches the signal and provides recovery instructions.
*   **Retries**: Network calls to AWS are wrapped in retry logic with exponential backoff.
*   **Validation**: Inputs (Region, AMIs, IDs) are validated against Regex patterns before use.

### 4. Advanced Logging
Logs are structured, timestamped, and color-coded.
*   **Console**: Human-readable with colors.
*   **File**: Machine-readable (plain text) saved to `*.log`.

---

## ⚙ Configuration

All settings are centralized in `config.env`.

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `eu-west-1` | Target AWS Region |
| `PROJECT_TAG` | `AutomationLab` | Tag used for billing and cleanup |
| `NAME_PREFIX` | `automationlab` | Prefix for resource naming |
| `INSTANCE_TYPE` | `t3.micro` | EC2 Instance Size |

To override without changing the file:
```bash
AWS_REGION=us-east-1 ./orchestrate.sh apply
```

---

## 📂 Project Structure

```text
.
├── orchestrate.sh          # Main entry point (CLI)
├── config.env              # Central configuration
├── lib/
│   ├── common.sh           # Shared utilities & AWS wrappers
│   ├── logging.sh          # Logging framework
│   ├── state.sh            # State file management
│   └── validation.sh       # Input validation logic
├── scripts/
│   ├── create_security_group.sh
│   ├── create_ec2.sh
│   ├── create_s3_bucket.sh
│   └── cleanup_resources.sh
└── .state/
    └── default.json        # Infrastructure state (do not edit manually)
```

---

## 📝 License

This project is part of the DevOps Automation Lab.
