# infra-iac

Multi-cloud Infrastructure-as-Code managed with **Terragrunt** (Terraform wrapper), following an atoms → molecules → organisms layering pattern.

## Architecture

### Module layers

| Layer | Directory | Description |
|---|---|---|
| **Atoms** | `atoms/` | Single-purpose Terraform modules (vpc, ec2, ecs/task, etc.) |
| **Molecules** | `molecules/` | Compositions of atoms (e.g. network = vpc + security group) |
| **Organisms** | `organisms/` | Full application stacks (e.g. K3s cluster) |
| **Instances** | `aws/`, `gcp/`, `oci/` | Terragrunt units that deploy modules to real environments |

### Directory layout

```
infra-iac/
├── atoms/                          # Reusable Terraform modules
│   ├── aws/
│   │   ├── network/vpc/
│   │   ├── network/security_group/
│   │   ├── cloud_map/
│   │   ├── ecs/cluster/
│   │   ├── ecs/service/
│   │   ├── ecs/task/
│   │   ├── ec2/
│   │   └── eks/
│   ├── gcp/  (gke, network)
│   ├── oci/  (network/vcn)
│   └── cloudflare/  (domain, tunnel)
├── molecules/aws/
│   ├── network/                    # vpc + security_group
│   └── ecs/app/                    # ecs/service + cloud_map
├── organisms/aws/k3s/cluster/      # Full K3s cluster stack
├── aws/accounts/personal/us_east_1/   # Terragrunt instances (AWS)
├── gcp/projects/regulus/              # Terragrunt instances (GCP)
├── oci/tenancy/regulus/               # Terragrunt instances (OCI)
├── tests/                          # Terratest unit tests
│   ├── fixtures/                   # One fixture per module
│   ├── unit/                       # Test files (*_test.go)
│   ├── helpers/                    # Test utilities
│   └── cmd/coverage/               # HTML coverage report generator
├── scripts/                        # Utility scripts
├── Makefile                        # lint / test / coverage targets
├── .tflint.hcl                     # TFLint config (AWS ruleset)
└── mise.toml                       # Pinned tool versions
```

### Dependency chain (AWS)

```
VPC → Internal Domain → ECS Cluster → Applications
```

Managed by Terragrunt `dependency` blocks — ordering is automatic with `run-all`.

## Development

### Prerequisites

```bash
mise install   # installs terraform, terragrunt, go, tflint (see mise.toml)

export AWS_PROFILE=personal          # AWS CLI profile for the personal account
export CLOUDFLARE_API_TOKEN=<token>  # Cloudflare API token
```

### Lint

```bash
make lint          # terraform fmt -check + tflint on all atoms/ and molecules/
make lint-fmt      # format check only
make lint-tflint   # tflint only
```

### Test

All tests are unit tests — they use mock AWS credentials and never contact real AWS.

```bash
make test-unit     # run all Terratest unit tests

# Run a single test
cd tests && go test -tags=unit -v -run TestVpcValidate ./unit/...
```

### Coverage report

```bash
make coverage-report   # generates coverage.html
# then open coverage.html in your browser
```

The report shows which atoms/molecules/organisms have `validate` and `plan` tests.

## Terragrunt quick reference

```bash
# Initialize all units (respects dependency order)
terragrunt run-all init

# Plan all
terragrunt run-all plan

# Apply all
terragrunt run-all apply

# Single unit
cd aws/accounts/personal/us_east_1/network/vpc && terragrunt apply

# Dependency graph
terragrunt graph-dependencies
```

## Terraform backend

All state in S3 + DynamoDB locking (`root.hcl`):
- Bucket: `infra-terraform-state-seila`
- Lock table: `infra-terraform-lock-table`
- Region: `us-east-1`

## Further reading

- [K3s Cluster on AWS](aws/accounts/personal/us_east_1/applications/k3s/README.md) — K3s + ArgoCD GitOps setup, deploy/destroy guide, credentials, troubleshooting
