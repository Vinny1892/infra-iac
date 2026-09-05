#!/usr/bin/env bash
set -euo pipefail

# O deploy automatizado usa a chave dedicada do Mercurio para criar as VMs; o
# fluxo humano preserva a chave pessoal do operador como padrao.
if [ "${K3S_USE_MERCURIO_KEY:-false}" = "true" ]; then
  exec op read "op://Lab-IAC/Mercurio SSH/public key"
else
  exec op read "op://Personal/Pessoal/public key"
fi
