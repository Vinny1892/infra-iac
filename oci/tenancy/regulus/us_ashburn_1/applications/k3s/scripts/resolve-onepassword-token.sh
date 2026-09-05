#!/usr/bin/env bash
set -euo pipefail

# O deploy automatizado injeta a service account restrita ao Lab-IAC. O fluxo
# humano preserva o comportamento historico e busca no vault IAM a credencial
# dedicada do External Secrets Operator.
if [ -n "${K3S_ONEPASSWORD_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  printf '%s' "$K3S_ONEPASSWORD_SERVICE_ACCOUNT_TOKEN"
else
  exec op item get "Service Account Auth Token: K3s" \
    --vault IAM \
    --fields credencial \
    --reveal
fi
