# infra-iac

Multi-cloud Infrastructure-as-Code managed with **Terragrunt** (Terraform wrapper).

## Apply Order (dependency chain - automated by Terragrunt)

1. Network/VPC
2. Internal Domain
3. ECS Cluster
4. Applications

## Quick Start

```bash
# Initialize all units
terragrunt run-all init

# Plan all
terragrunt run-all plan

# Apply all (respects dependency order)
terragrunt run-all apply

# Single unit
cd aws/account/personal/network/vpc && terragrunt apply
```

## Documentation

- [K3s Cluster on AWS](aws/accounts/personal/us_east_1/applications/k3s/README.md) — K3s + ArgoCD GitOps setup, deploy/destroy guide, credentials, troubleshooting
