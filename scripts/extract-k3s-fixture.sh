#!/usr/bin/env bash
set -eu

# Extract HCL from K3s organism terragrunt.hcl generate blocks
# and write standalone .tf files into tests/fixtures/k3s_extracted/

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/organisms/aws/k3s/cluster/terragrunt.hcl"
DEST="${REPO_ROOT}/tests/fixtures/k3s_extracted"

mkdir -p "${DEST}"

# Extract the terraform{} block only (required_providers) from provider block
# Strip the provider "aws" block since we override it with mock credentials
awk '
  /^generate "provider"/ { found=1; next }
  found && /contents.*<<EOF/ { capture=1; next }
  capture && /^EOF$/ { capture=0; found=0; next }
  capture { print }
' "${SRC}" | sed 's/\$\${\([^}]*\)}/${\1}/g' | awk '
  /^provider "aws"/ { skip=1 }
  skip && /^}/ { skip=0; next }
  !skip { print }
' > "${DEST}/provider.tf"

# Extract generate "main" block contents (between <<EOF and EOF)
# Replace data.aws_caller_identity with a variable so terraform plan works without
# real AWS credentials (data "aws_caller_identity" makes a live STS API call).
awk '
  /^generate "main"/ { found=1; next }
  found && /contents.*<<EOF/ { capture=1; next }
  capture && /^EOF$/ { capture=0; found=0; next }
  capture { print }
' "${SRC}" | sed 's/\$\${\([^}]*\)}/${\1}/g' \
  | sed 's|data "aws_caller_identity" "current" {}|variable "account_id" {\n  type    = string\n  default = "123456789012"\n}|' \
  | sed 's/data\.aws_caller_identity\.current\.account_id/var.account_id/g' \
  > "${DEST}/main.tf"

# Mock provider for testing (no real AWS credentials needed)
cat > "${DEST}/provider_override.tf" <<'OVERRIDE'
provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  access_key                  = "mock"
  secret_key                  = "mock"
}

provider "tls" {}
OVERRIDE

# Symlink scripts directory (needed for templatefile)
SCRIPTS_SRC="${REPO_ROOT}/organisms/aws/k3s/cluster/scripts"
if [ -d "${SCRIPTS_SRC}" ]; then
  rm -f "${DEST}/scripts"
  ln -sf "${SCRIPTS_SRC}" "${DEST}/scripts"
fi

echo "K3s fixture extracted to ${DEST}"
