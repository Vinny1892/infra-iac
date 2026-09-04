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

## [ ] `pg-teste` nasceu vazio em vez de ser restaurado do backup

**Onde:** `oci/tenancy/regulus/us_ashburn_1/applications/k3s/argocd/manifests/postgres/cluster.yaml`,
bloco `bootstrap`.

**O que está errado:** o manifesto usa `bootstrap.initdb`, que cria um banco
vazio. Na recriação da VM em 03/09/2026 a intenção era **restaurar** o banco a
partir dos backups que já estavam no S3 — não criar um novo. O cluster subiu com
system ID novo às 20:47 e as bases de 31/08 a 02/09 em
`s3://backup-longhorn-k3s/cnpg/pg-teste/` ficaram órfãs.

**Consequência: não existe backup do cluster atual, e nenhum WAL foi arquivado
desde a recriação.** A cadeia:

1. O plugin Barman roda `barman-cloud-check-wal-archive` antes de arquivar e, num
   cluster recém-bootstrapado, **exige o prefixo vazio**.
2. Encontra os artefatos da encarnação anterior e falha com
   `WAL archive check failed for server pg-teste: Expected empty archive`.
3. Sem archiving, o backup base agendado de 04/09 03:30 travou em `started` — no
   S3 há só o `backup.info` de 852 bytes, sem `data.tar`. Último WAL arquivado:
   `00000001000000000000000F`, de 01/09.

O PVC ainda está folgado (144M de 4.9G, 10 segmentos em `pg_wal`) só porque o
banco está ocioso; o Postgres não recicla WAL não arquivado, então isso cresce
até encher.

**NÃO apague `cnpg/pg-teste/` no S3.** É a fonte do restore que falta fazer, não
lixo de um cluster morto — é justamente o que a correção precisa ler.

**Como consertar:** trocar o bootstrap por `recovery` apontando para o
ObjectStore, no formato de `externalClusters` do plugin CNPG-I:

```yaml
bootstrap:
  recovery:
    source: pg-teste-origem
externalClusters:
  - name: pg-teste-origem
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: s3-backup
        serverName: pg-teste
```

Conferir a sintaxe contra a doc das versões em uso — plugin
`ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.14.0`, operator
`cloudnative-pg:1.30.0` — antes de aplicar; a config do Barman migrou de
`spec.backup.barmanObjectStore` para a CRD do plugin e os exemplos antigos não
valem mais.

**Não dá para converter no lugar.** Um cluster criado por `initdb` não vira
cluster restaurado por edição de manifesto: é preciso apagar o `Cluster` e o PVC
`pg-teste-1` e deixar o ArgoCD re-bootstrapar pelo caminho de recovery. Hoje o
custo disso é zero — são 20h de um banco de teste ocioso cujos WALs nunca foram
arquivados. Quanto mais tarde, pior.

**Detalhe que engana — por isso passou despercebido:** todo indicador de rotina
diz que está tudo bem. `kubectl get cluster` responde `Cluster in healthy
state`, a Application do ArgoCD fica `Synced/Healthy`, o pod segue `2/2
Running`. A falha aparece só em `.status.conditions`
(`ContinuousArchiving=False`) e no log do container `postgres`, que carrega o
sidecar do plugin. Mesma família dos casos 16–18 do `CLAUDE.md`: verificação que
mede a camada errada passa enquanto o sistema está quebrado.

**Cuidados na implementação:**

- **`serverName` do cluster restaurado precisa ser diferente do de origem.** Se
  o cluster novo arquivar sob `pg-teste`, ele escreve por cima do histórico que
  acabou de restaurar — e o `check-wal-archive` volta a reclamar de arquivo não
  vazio no próximo ciclo. O restore lê de `pg-teste`; o cluster vivo deve
  arquivar em outro nome.
- Isso vale para **toda recriação**: sem `serverName` versionado, o mesmo
  impasse volta no próximo `destroy`/`deploy`. É defeito estrutural, não
  acidente de uma vez.
- Limpar o backup travado `pg-teste-diario-20260904033000` (`started` desde
  04/09 03:30) — ele não vai concluir.
- **Vale um alerta em `ContinuousArchiving`** no victoria-metrics. Descobrir isso
  dependeu de alguém ler `.status.conditions` na mão; o próximo caso passa em
  silêncio do mesmo jeito.

## [ ] Probe do Cowrie mede TCP, não login — e domina a captura

**Onde:** `oci/tenancy/regulus/us_ashburn_1/applications/k3s/argocd/manifests/cowrie/deployment.yaml:91-100`
— `readinessProbe` e `livenessProbe` são `tcpSocket` na 2222, a cada 10s e 30s.

São dois defeitos no mesmo lugar.

**1. A probe não consegue ver o modo de falha que já aconteceu.** O caso 18 do
`CLAUDE.md` foi o PVC vazio montado sobre `var/`: o Cowrie travava **no momento
do login**, e TCP era justamente a única camada que continuava funcionando. Pod
`1/1 Running`, Application `Synced/Healthy`, banner respondendo, honeypot
inutilizável. Foi descoberto tentando usar, não por check nenhum. Enquanto a
probe for TCP, esse modo de falha volta em silêncio.

**2. A probe polui a captura.** Em 24h de log, **9.571 das 11.088 conexões (86%)
vêm de `10.42.0.1`** — o gateway do CNI, ou seja, o kubelet — nas cadências de
10s e 30s das duas probes. Qualquer leitura de volume de ataque tirada do log
cru está errada por um fator de 7. O tráfego real do período foi 1.517 conexões,
1.122 tentativas de login e 497 comandos, de IPs externos de verdade
(45.156.87.13 com 785, 45.148.10.240, 91.92.47.35).

**Como consertar:** trocar por uma probe que **complete um login e rode um
comando**. É viável dentro da própria imagem, sem sidecar nem imagem nova —
conferido no pod (`cowrie/cowrie:3.0.13`):

- `python3` 3.13.5 existe;
- `twisted.conch.client`, `cryptography` e `bcrypt` estão presentes;
- **`paramiko` não está** — não dá para copiar o teste manual que a doc sugere;
- **não há `sh` na imagem.** A probe tem de ser
  `exec: command: ["python3", "-c", "..."]`; qualquer coisa via `sh -c` falha com
  `executable file not found in $PATH`.

**A tensão a resolver de propósito:** o check que prova que funciona também
contamina os dados que o honeypot existe para coletar. Usar uma credencial
dedicada no `userdb.txt` (algo como um usuário `healthcheck`) deixa as sessões
da probe filtráveis por username no VictoriaLogs, em vez de indistinguíveis de
um atacante. Enquanto a probe for TCP, o filtro possível é excluir
`10.42.0.1` nas consultas — e isso precisa estar nos painéis, senão os números
enganam quem olhar.

**Cuidados na implementação:**

- **Baixar a cadência.** Um login completo a cada 10s é caro para um pod com
  teto baixo de CPU de propósito, e não compra nada: é replica única, sem
  desvio de tráfego dependendo de readiness.
- **Cuidado com liveness que faz login.** Se o teste for pesado ou flaky, ele
  reinicia o pod sob carga hostil — exatamente quando o honeypot está sendo
  útil. Considere login só na readiness e manter TCP na liveness.
- Se o teste in-image se mostrar chato de escrever com `conch`, a alternativa é
  um CronJob que faça o login de fora e alerte. Aceita que o pod fique `Ready`
  quebrado, mas ainda avisa — hoje nada avisa.

## [ ] Métricas de container duplicadas no VictoriaMetrics: todo `sum()` vale 2x

**Onde:** `oci/tenancy/regulus/us_ashburn_1/applications/k3s/argocd/values/victoria-metrics.yaml`
— hoje o arquivo **não tem** seção `kubelet`, então vale o scrape default do
chart `victoria-metrics-k8s-stack`.

**O defeito:** o kubelet expõe as mesmas métricas em dois endpoints, e o vmagent
raspa os dois sob o mesmo `job="kubelet"`, na mesma `instance`. Resultado: cada
container tem **duas séries idênticas**, distinguíveis só por `metrics_path`
(`/metrics/cadvisor`, que traz o label `image`, e `/metrics/resource`, que não
traz).

Colidem exatamente três métricas, 68 séries cada:

- `container_cpu_usage_seconds_total`
- `container_memory_working_set_bytes`
- `container_start_time_seconds`

As demais de `/metrics/resource` (`pod_*`, `node_*_usage`, `*_swap_*`) só
existem lá e **não** colidem — motivo para corrigir sem desligar o endpoint.

**Consequência: qualquer `sum()` ou `count()` de CPU ou memória por namespace,
pod ou cluster devolve o dobro.** Medido: o namespace `minecraft` somava
11.366 Mi contra 5.685 Mi reais; o container do Grafana aparece duas vezes com
243 Mi cada.

**Pior que os painéis: as recording rules do próprio chart.** Duas regras
agregam com `sum` sobre a métrica duplicada e gravam o resultado inflado —
`node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m` e
`:sum_irate`. Tudo que consome esses registros herda o erro, inclusive alerta.
Antes de fechar, revisar se algum alerta de saturação dispara (ou deixa de
disparar) por causa disso.

**Como consertar:** manter o `/metrics/cadvisor` como fonte — tem labels mais
ricos e é o que os dashboards do chart assumem — e derrubar as três métricas no
scrape de `/metrics/resource`, via `metricRelabelConfigs` com `action: drop` em
`__name__`. Desligar o endpoint inteiro é pior: perde-se `pod_*`, `node_*_usage`
e as de swap.

**Detalhe que engana — por isso passou 20h sem ninguém notar:** só `sum` e
`count` inflam. `avg` de duas séries idênticas dá o valor certo, e `max`, `min`
e `topk` também. Então metade dos painéis está correta, nenhum erro aparece em
log, e o número errado é plausível — 11 GB de Minecraft não é absurdo o
suficiente para levantar suspeita. Foi encontrado por acidente, comparando com
`kubectl top` durante o dimensionamento do split das VMs.

**Cuidados na implementação:**

- **`kubectl top` não é afetado e não serve de validação depois.** O
  metrics-server lê o kubelet direto, sem passar pelo VictoriaMetrics — foi
  justamente a discrepância entre os dois que revelou o problema. Validar
  conferindo que `count by (__name__) ({metrics_path="/metrics/resource"})` não
  lista mais as três, e que a soma por namespace passa a bater com o `top`.
- **Sobrescrever `kubelet.vmScrape` substitui a lista de endpoints do chart**,
  não faz merge. Renderizar com os values reais antes de commitar:
  `helm template test victoria-metrics-k8s-stack --repo https://victoriametrics.github.io/helm-charts/ --version 0.91.2 -f argocd/values/victoria-metrics.yaml`.
- Versão do chart em dois lugares (seed Terraform e Application do ArgoCD): se
  divergirem, o `selfHeal` reverte o seed no primeiro sync.
- Os dados históricos já gravados continuam dobrados. Comparação com o passado
  vai mostrar um degrau na correção — não é regressão.
