# Gemini CLI Project Context: infra-iac

## Project Overview
This repository is a multi-cloud Infrastructure-as-Code (IaC) project managed using **Terragrunt** as a wrapper for **Terraform**. It automates the provisioning and management of resources across **AWS**, **GCP**, **OCI (Oracle Cloud)**, and **Cloudflare**.

The project follows a "Molecular" architecture pattern (inspired by Atomic Design) for its reusable Terraform modules, organized into:
- **Atoms**: Single-purpose building blocks (e.g., a single VPC, a security group, or an S3 bucket).
- **Molecules**: Compositions of atoms that form a functional unit (e.g., a network stack with VPC and security groups).
- **Organisms**: Complex, high-level assemblies (e.g., a complete K3s cluster or an ECS application environment).

### Main Technologies
- **IaC**: Terragrunt, Terraform (>= 1.9.2)
- **Cloud Providers**: AWS (~> 5.0), GCP, OCI (~> 6.0), Cloudflare
- **Orchestration**: ECS, EKS, K3s (Lightweight Kubernetes)
- **GitOps**: ArgoCD (for K3s workloads)
- **Configuration Management**: Ansible (for EC2 instances, via `minecraft-ansible` submodule)
- **State Management**: AWS S3 (backend) with DynamoDB (locking)
- **Testing**: Terratest (Go) for unit testing with mock providers.

---

## Directory Structure

```text
.
├── root.hcl                # Global Terragrunt configuration (S3 backend, state locking)
├── atoms/                  # Reusable low-level Terraform modules (AWS, GCP, OCI, Cloudflare)
├── molecules/              # Intermediate-level Terraform modules (compositions)
├── organisms/              # High-level Terraform modules (complex application stacks)
├── aws/                    # AWS instance layer (accounts/personal/us_east_1)
│   └── accounts/personal/  # AWS Account: personal
│       └── us_east_1/      # Region: us-east-1
│           ├── _region.hcl # Region-specific provider config (inherits from root.hcl)
│           ├── network/    # VPC and networking units
│           ├── internal_domain/ # CloudMap service discovery
│           ├── ecs_cluster/ # ECS orchestration layer
│           └── applications/ # ECS/EC2/K3s application units
├── gcp/                    # GCP instance layer (projects/regulus)
├── oci/                    # OCI instance layer (tenancy/regulus)
├── cloudflare/             # Cloudflare module definitions
├── tests/                  # Terratest unit tests and fixtures
├── scripts/                # Utility scripts (e.g., K3s fixture extraction)
├── Makefile                # Lint, test, and coverage targets
├── .tflint.hcl             # TFLint configuration (AWS ruleset)
└── mise.toml               # Tool version management (Terraform, Terragrunt, Go, TFLint)
```

---

## Core Workflows & Commands

### Terragrunt (General IaC)
Terragrunt commands should be run within specific unit directories or from the root for bulk operations. Always refer to the **Makefile** as the source of truth for linting, testing, and validation commands.

```bash
# Initialize all units (respects dependency order)
terragrunt run-all init

# Plan/Apply all units
terragrunt run-all plan
terragrunt run-all apply

# Destroy all units (reverse dependency order)
terragrunt run-all destroy

# Single unit operations
cd aws/accounts/personal/us_east_1/network/vpc
terragrunt plan
terragrunt apply

# View dependency graph
terragrunt graph-dependencies
```

### Lint & Test (Makefile targets)
```bash
make lint            # terraform fmt -check + tflint on atoms/ and molecules/
make lint-fmt        # terraform fmt check only
make lint-tflint     # tflint only
make test-unit       # Terratest unit tests (mock AWS, no real API calls)
make coverage-report # Generate coverage.html showing which modules have tests
```

### K3s Cluster Lifecycle
The K3s cluster has a specialized deployment script and Makefile targets.

```bash
# Full deployment (Infrastructure + ArgoCD + Apps)
cd aws/accounts/personal/us_east_1 && make k3s-deploy

# Destruction order (manual cleanup of K8s-managed resources first)
# 1. Pre-destroy: clean up NLBs, TGs, SGs, SSM, OIDC bucket
cd aws/accounts/personal/us_east_1 && bash applications/k3s/pre-destroy.sh
# 2. Destroy Helm releases
cd aws/accounts/personal/us_east_1/applications/k3s/helms && terragrunt destroy
# 3. Destroy cluster infra
cd aws/accounts/personal/us_east_1/applications/k3s/cluster && terragrunt destroy
```

### Ansible (Minecraft)
Located in `aws/accounts/personal/us_east_1/applications/ec2/minecraft/minecraft-ansible/`.

```bash
make check    # Verify ansible communication
make exec     # Run playbooks
make test     # Run molecule tests
```

---

## Development Conventions

### 1. Configuration Hierarchy
- **`root.hcl`**: Defines the remote state backend. Every `terragrunt.hcl` should `include` this.
- **`_region.hcl` / `_provider.hcl`**: Generate provider blocks for specific regions or clouds.
- **`terragrunt.hcl`**: Every leaf directory (unit) contains exactly one `terragrunt.hcl` which defines the `source` module, `inputs`, and often generates the `main.tf` inline.

### 2. Module Usage
- **Atoms**: `network/vpc`, `network/security_group`, `ecs/cluster`, `ecs/service`, `ecs/task`, `ec2`, `eks`, `gke`, `vcn`, `domain`, `tunnel`.
- **Molecules**: `network` (vpc + sg), `ecs/app` (service + cloud_map).
- **Organisms**: `k3s/cluster`.
- Do not edit `.tf` files in unit directories directly; they are generated by Terragrunt `generate` blocks.

### 3. State & Backend
- State is stored in S3: `infra-terraform-state-seila`.
- Locking is managed by DynamoDB: `infra-terraform-lock-table`.
- Region: `us-east-1`, Profile: `personal`.
- State keys are auto-generated from the directory path.

### 4. Credentials & Environment
Before running commands, export the required environment variables (often loaded via `load_tf_vinny_root` in `.bashrc`):
```bash
export AWS_PROFILE=personal
export CLOUDFLARE_API_TOKEN=<token>
```

### 5. Testing Infrastructure
- Tests use **Terratest** and are located in `tests/unit/`.
- All tests use the `//go:build unit` tag and mock providers to avoid real API calls.
- **Fixture pattern**: Each module has a corresponding fixture in `tests/fixtures/` with a mock provider.
- **K3s organism test**: Requires running `scripts/extract-k3s-fixture.sh` once before execution.

---

## Key Files & Applications
- `root.hcl`: Centralized backend and state configuration.
- `CLAUDE.md`: Detailed guidance on commands and architecture.
- `README.md`: High-level overview and dependency chain.
- **ECS services**: Loki (log aggregation), Apache Superset (analytics).
- **EC2 instances**: Minecraft server, Postgres (AWS + Cloudflare), K3S nodes, OpenClaw.
