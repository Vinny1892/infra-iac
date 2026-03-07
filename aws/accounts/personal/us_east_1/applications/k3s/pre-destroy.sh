#!/bin/bash
# Cleans up Kubernetes-spawned resources that Terraform does not manage.
#
# Run order (called by deploy.sh destroy):
#   1. kubectl delete applications -n argocd --all  <- removes ArgoCD-managed resources
#   2. bash pre-destroy.sh              <- this script (cleans K8s-managed AWS resources)
#   3. terragrunt destroy (helms/)      <- removes ArgoCD seed + secrets
#   4. terragrunt destroy (cluster/)    <- destroys cluster infra
#
# Resources cleaned up:
#   - NLBs created by the AWS Load Balancer Controller (+ their ENIs)
#   - Target Groups created by the LB Controller
#   - Security Groups created by the LB Controller
#   - OIDC S3 bucket objects (belt-and-suspenders; TF has force_destroy=true)
#
# NOTE: SSM /k3s/kubeconfig is NOT deleted here — helms/ uses it to configure
#       the kubernetes provider. It is deleted automatically when the cluster
#       EC2 instances are terminated.

set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$SCRIPT_DIR/cluster"
REGION="us-east-1"
export AWS_PROFILE="${AWS_PROFILE:-personal}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[PRE-DESTROY]${NC} $*"; }
warn() { echo -e "${YELLOW}[PRE-DESTROY]${NC} $*"; }
err()  { echo -e "${RED}[PRE-DESTROY]${NC} $*" >&2; }

# -----------------------------------------------------------------------------
# Read cluster state
# -----------------------------------------------------------------------------
get_cluster_info() {
  log "Reading cluster outputs from Terragrunt state..."

  VPC_ID=$(cd "$CLUSTER_DIR" && terragrunt output -raw vpc_id 2>/dev/null) || {
    err "Could not read vpc_id from cluster state. Is the cluster deployed?"
    exit 1
  }

  ACCOUNT_ID=$(aws sts get-caller-identity \
    --region "$REGION" --query Account --output text)

  OIDC_BUCKET="k3s-oidc-${ACCOUNT_ID}"

  log "VPC:         $VPC_ID"
  log "OIDC bucket: $OIDC_BUCKET"
}

# -----------------------------------------------------------------------------
# NLBs created by the AWS Load Balancer Controller
# -----------------------------------------------------------------------------
delete_k8s_load_balancers() {
  log "Scanning for Kubernetes-managed Load Balancers in VPC $VPC_ID..."

  local all_arns
  all_arns=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
    --output text)

  local k8s_arns=()
  for arn in $all_arns; do
    local tag_keys
    tag_keys=$(aws elbv2 describe-tags \
      --resource-arns "$arn" \
      --region "$REGION" \
      --query "TagDescriptions[0].Tags[].Key" \
      --output text 2>/dev/null || true)

    if echo "$tag_keys" | grep -qE "kubernetes\.io/|elbv2\.k8s\.aws/"; then
      k8s_arns+=("$arn")
    fi
  done

  if [[ ${#k8s_arns[@]} -eq 0 ]]; then
    log "No Kubernetes-managed load balancers found."
    return
  fi

  for arn in "${k8s_arns[@]}"; do
    log "  Deleting LB: $arn"
    aws elbv2 delete-load-balancer \
      --load-balancer-arn "$arn" --region "$REGION"
  done

  log "Waiting for load balancers to be fully deleted (ENIs released)..."
  for arn in "${k8s_arns[@]}"; do
    aws elbv2 wait load-balancers-deleted \
      --load-balancer-arns "$arn" --region "$REGION" || true
  done

  log "Load balancers deleted."
}

# -----------------------------------------------------------------------------
# Target Groups left behind by the LB Controller
# -----------------------------------------------------------------------------
delete_k8s_target_groups() {
  log "Scanning for Kubernetes-managed Target Groups in VPC $VPC_ID..."

  local all_tg_arns
  all_tg_arns=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
    --output text 2>/dev/null || true)

  for arn in $all_tg_arns; do
    local tag_keys
    tag_keys=$(aws elbv2 describe-tags \
      --resource-arns "$arn" \
      --region "$REGION" \
      --query "TagDescriptions[0].Tags[].Key" \
      --output text 2>/dev/null || true)

    if echo "$tag_keys" | grep -qE "kubernetes\.io/|elbv2\.k8s\.aws/"; then
      log "  Deleting Target Group: $arn"
      aws elbv2 delete-target-group \
        --target-group-arn "$arn" --region "$REGION" || true
    fi
  done
}

# -----------------------------------------------------------------------------
# Security Groups created by the LB Controller
# -----------------------------------------------------------------------------
delete_k8s_security_groups() {
  log "Scanning for Kubernetes-managed Security Groups in VPC $VPC_ID..."

  local sg_ids
  sg_ids=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text)

  local k8s_sgs=()
  for sg_id in $sg_ids; do
    local tag_keys
    tag_keys=$(aws ec2 describe-security-groups \
      --region "$REGION" \
      --group-ids "$sg_id" \
      --query "SecurityGroups[0].Tags[].Key" \
      --output text 2>/dev/null || true)

    if echo "$tag_keys" | grep -qE "kubernetes\.io/|elbv2\.k8s\.aws/"; then
      k8s_sgs+=("$sg_id")
    fi
  done

  if [[ ${#k8s_sgs[@]} -eq 0 ]]; then
    log "No Kubernetes-managed security groups found."
    return
  fi

  # Revoke cross-references first so deletion order doesn't matter
  for sg_id in "${k8s_sgs[@]}"; do
    log "  Revoking ingress rules referencing $sg_id..."
    local referencing
    referencing=$(aws ec2 describe-security-groups \
      --region "$REGION" \
      --filters "Name=ip-permission.group-id,Values=$sg_id" \
      --query "SecurityGroups[].GroupId" \
      --output text 2>/dev/null || true)

    for ref_sg in $referencing; do
      aws ec2 revoke-security-group-ingress \
        --region "$REGION" \
        --group-id "$ref_sg" \
        --source-group "$sg_id" \
        --protocol all 2>/dev/null || true
    done
  done

  for sg_id in "${k8s_sgs[@]}"; do
    log "  Deleting Security Group: $sg_id"
    aws ec2 delete-security-group \
      --group-id "$sg_id" --region "$REGION" \
      || warn "  Could not delete $sg_id (may have remaining dependencies)"
  done

  log "Security groups cleaned up."
}

# -----------------------------------------------------------------------------
# OIDC bucket – empty it so Terraform can delete even if force_destroy fails
# -----------------------------------------------------------------------------
empty_oidc_bucket() {
  log "Checking OIDC bucket $OIDC_BUCKET..."

  if ! aws s3api head-bucket \
      --bucket "$OIDC_BUCKET" \
      --region "$REGION" 2>/dev/null; then
    warn "Bucket $OIDC_BUCKET not found, skipping."
    return
  fi

  log "Emptying bucket..."
  aws s3 rm "s3://${OIDC_BUCKET}" \
    --recursive --region "$REGION" \
    && log "Bucket emptied." \
    || warn "Failed to empty bucket (may already be empty)."
}

# -----------------------------------------------------------------------------
main() {
  log "========================================"
  log "  K3s pre-destroy cleanup"
  log "========================================"

  get_cluster_info
  delete_k8s_load_balancers
  delete_k8s_target_groups
  delete_k8s_security_groups
  empty_oidc_bucket

  log "========================================"
  log "  Pre-destroy cleanup complete."
  log "========================================"
}

main
