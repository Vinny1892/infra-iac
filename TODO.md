# TODO

Pendências conhecidas, com contexto suficiente para alguém pegar do zero.

## [ ] `deploy.sh` deve gravar o kubeconfig no 1Password ao fim do deploy

**Onde:** `oci/tenancy/regulus/us_ashburn_1/applications/k3s/deploy.sh`, na
função `fetch_kubeconfig()` — logo depois de salvar em `$KUBECONFIG_PATH`.

**Destino:** item `K3s OCI kubeconfig` (SECURE_NOTE) no vault `Lab-IAC`, campo
`notesPlain`. Atualiza com:

```bash
op item edit "K3s OCI kubeconfig" --vault Lab-IAC \
  "notesPlain=$(cat "$KUBECONFIG_PATH")" >/dev/null
```

**Por quê:** o item do cofre é a cópia de referência do kubeconfig, mas hoje só
é atualizado à mão — e ninguém lembra. Cada recriação da VM gera uma **CA nova**
do K3s, então o conteúdo guardado vira lixo silenciosamente: continua sendo um
YAML válido, com o IP certo (o IP é reservado e não muda), e falha só na hora de
usar, com `x509: certificate signed by unknown authority`.

Foi o que aconteceu em 03/09/2026: o item trazia a CA `k3s-server-ca@1787809311`
(27/08) enquanto o cluster recriado no mesmo dia servia
`k3s-server-ca@1788467809`. Corrigido manualmente puxando `/etc/rancher/k3s/k3s.yaml`
da VM por SSH, do mesmo jeito que o `fetch_kubeconfig` já faz.

**Detalhe que engana:** comparar o item do cofre com o kubeconfig local acusa
apenas a linha `server:`. Os certificados são blobs base64 que diferem sem que
o diff diga nada de útil. Para saber se a cópia presta, compare a CA com a que o
apiserver apresenta:

```bash
grep -m1 certificate-authority-data <arquivo> | awk '{print $2}' \
  | base64 -d | openssl x509 -noout -subject
openssl s_client -connect <ip>:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer
```

Mesma família dos casos 16–18 do `CLAUDE.md`: verificação que mede a camada
errada passa enquanto o sistema está quebrado.

**Cuidados na implementação:**

- `op item edit` é escrita em cofre compartilhado — só deve rodar num deploy que
  chegou ao fim, nunca num caminho parcial.
- Se o `op` não estiver autenticado o `preflight_check` já barra antes; ainda
  assim, a falha da escrita não deve derrubar um deploy bem-sucedido — mas
  também **não pode ser mascarada** com `|| true` silencioso. Avise alto.
- Não ecoar o conteúdo do kubeconfig em log.
