#!/usr/bin/env bash
# Cria uma identidade AWS exclusiva para o Longhorn e materializa os dois
# Secrets Kubernetes a partir do 1Password. Nenhum segredo e escrito no Git.
set -euo pipefail

KUBECONFIG_PATH="${K3S_OCI_KUBECONFIG:-$HOME/.kube/k3s-oci.yaml}"
KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH")
AWS_PROFILE="${AWS_PROFILE:-personal}"
VAULT="Lab-IAC"
S3_ITEM="Longhorn AWS S3 Backup"
RCON_ITEM="Minecraft RCON"
IAM_USER="longhorn-backup-k3s"
BUCKET="backup-longhorn-k3s"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

require() {
  command -v "$1" >/dev/null || { echo "ERROR: $1 nao encontrado" >&2; exit 1; }
}

for command in aws kubectl op jq openssl; do require "$command"; done

if ! aws s3api head-bucket --bucket "$BUCKET" --profile "$AWS_PROFILE"; then
  echo "ERROR: bucket s3://$BUCKET indisponivel para o profile $AWS_PROFILE" >&2
  exit 1
fi

if ! aws iam get-user --user-name "$IAM_USER" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
  aws iam create-user --user-name "$IAM_USER" --profile "$AWS_PROFILE" >/dev/null
fi

cat >"$TMP_DIR/s3-policy.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::backup-longhorn-k3s"
    },
    {
      "Sid": "ManageLonghornBackupObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::backup-longhorn-k3s/*"
    }
  ]
}
EOF
aws iam put-user-policy --user-name "$IAM_USER" --policy-name longhorn-backup-k3s \
  --policy-document "file://$TMP_DIR/s3-policy.json" --profile "$AWS_PROFILE"

if ! op item get "$S3_ITEM" --vault "$VAULT" --format json >"$TMP_DIR/s3-item.json" 2>/dev/null; then
  aws iam create-access-key --user-name "$IAM_USER" --profile "$AWS_PROFILE" >"$TMP_DIR/access-key.json"
  access_key="$(jq -r '.AccessKey.AccessKeyId' "$TMP_DIR/access-key.json")"
  secret_key="$(jq -r '.AccessKey.SecretAccessKey' "$TMP_DIR/access-key.json")"
  op item template get Login | jq \
    --arg title "$S3_ITEM" \
    --arg username "$access_key" \
    --arg password "$secret_key" \
    '.title = $title | .fields |= map(if .id == "username" then .value = $username elif .id == "password" then .value = $password else . end)' \
    | op item create --vault "$VAULT" - >/dev/null
fi

if ! op item get "$RCON_ITEM" --vault "$VAULT" --format json >"$TMP_DIR/rcon-item.json" 2>/dev/null; then
  rcon_password="$(openssl rand -base64 32)"
  op item template get Password | jq \
    --arg title "$RCON_ITEM" \
    --arg password "$rcon_password" \
    '.title = $title | .fields |= map(if .id == "password" then .value = $password else . end)' \
    | op item create --vault "$VAULT" - >/dev/null
fi

op read "op://$VAULT/$S3_ITEM/username" >"$TMP_DIR/AWS_ACCESS_KEY_ID"
op read "op://$VAULT/$S3_ITEM/password" >"$TMP_DIR/AWS_SECRET_ACCESS_KEY"
op read "op://$VAULT/$RCON_ITEM/password" >"$TMP_DIR/rcon-password"
chmod 600 "$TMP_DIR"/*

"${KUBECTL[@]}" get namespace minecraft >/dev/null 2>&1 || "${KUBECTL[@]}" create namespace minecraft

"${KUBECTL[@]}" -n longhorn-system create secret generic longhorn-aws-backup \
  --from-file=AWS_ACCESS_KEY_ID="$TMP_DIR/AWS_ACCESS_KEY_ID" \
  --from-file=AWS_SECRET_ACCESS_KEY="$TMP_DIR/AWS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" -n minecraft create secret generic minecraft-rcon \
  --from-file=password="$TMP_DIR/rcon-password" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

echo "Bootstrap concluido: credencial AWS minima guardada no 1Password e Secrets aplicados."
