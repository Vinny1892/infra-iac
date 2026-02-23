# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Multi-cloud Infrastructure-as-Code project managing AWS, GCP, OCI (Oracle Cloud), and Cloudflare resources using Terraform. Includes Ansible-based configuration management for EC2 instances (via git submodule `minecraft-ansible`).

## Common Commands

All Terraform commands run from `aws/accounts/personal/us_east_1/`.

```bash
# Initialize all modules
make init

# Apply core infrastructure (network -> internal_domain -> ecs_cluster, in order)
make apply-core

# Destroy core infrastructure (reverse order)
make destroy-core

# Apply a single module
terraform -chdir=./network/vpc apply --auto-approve
terraform -chdir=./internal_domain apply --auto-approve
terraform -chdir=./ecs_cluster apply --auto-approve

# Plan a single module
terraform -chdir=./applications/ec2/minecraft plan

# Init a single module
terraform -chdir=./applications/ec2/minecraft init
```

Ansible/Minecraft testing (from `applications/ec2/minecraft/minecraft-ansible/`):
```bash
make check    # Verify ansible communication
make exec     # Run playbooks
make test     # Run molecule tests
```

## Architecture

### Multi-Cloud Layout

```
infra-iac/
├── aws/           # Primary cloud (VPC, ECS, EKS, EC2, CloudMap, Route53)
├── gcp/           # GKE clusters and networking
├── oci/           # Oracle Cloud (VCN, Compute instances)
└── cloudflare/    # DNS records and tunnels
```

### Reusable Modules vs Account Instances

Each cloud provider follows a **modules + instances** pattern:
- `{provider}/modules/` — reusable Terraform modules (the building blocks)
- `{provider}/accounts/{account}/{region}/` (AWS), `{provider}/projects/{project}/` (GCP), `{provider}/tenancies/{tenancy}/{region}/` (OCI) — concrete instantiations that call the modules

### AWS Module Inventory

- `network/vpc` — VPC with public/private subnets, NAT/Internet Gateways
- `network/security_group` — Security group definitions
- `network/route53_zone_association` — Route53 zone associations
- `cloud_map/internal_domain` — AWS CloudMap namespace (`regulus.internal`)
- `cloud_map/create_internal_dns` — Service discovery DNS entries
- `ecs/cluster`, `ecs/service`, `ecs/task` — ECS Fargate orchestration
- `ec2` — Standalone EC2 instances
- `eks` — Managed Kubernetes (EKS)

### OCI Module Inventory

- `network/vcn` — VCN with public/private subnets, Internet/NAT Gateways, route tables, security list
- `compute/instance` — OCI compute instance (VM.Standard.A1.Flex ARM by default)

See `oci/README.md` for setup instructions (OCI CLI, credentials, env vars).

### AWS Apply Order (dependency chain)

1. **Network/VPC** — foundational networking
2. **Internal Domain** — CloudMap service discovery
3. **ECS Cluster** — container orchestration layer
4. **Applications** — services deployed on ECS, EC2, or K3S

### Applications

**ECS services:** Loki (log aggregation), Apache Superset (analytics)
**EC2 instances:** Minecraft server, Postgres database, K3S server/agent nodes, OpenClaw

### Terraform Backend

All state is stored in S3 with DynamoDB locking:
- Bucket: `infra-terraform-state-seila`
- Lock table: `infra-terraform-lock-table`
- Region: `us-east-1`
- AWS Profile: `personal`
- Each module has a unique state key path in its `backend.tf`

### Terraform Version

Requires Terraform >= v1.9.2. Primary AWS provider: `~> 5.0`. OCI provider: `~> 6.0`.
