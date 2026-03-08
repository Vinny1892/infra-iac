# Infraestrutura de Testes e Linting

Este documento descreve como funciona a suite de testes e linting do projeto, quais ferramentas são utilizadas e como criar novos testes.

## Visão geral

| Camada | Ferramenta | O que verifica |
|---|---|---|
| Formatação | `terraform fmt` | Estilo e indentação dos arquivos `.tf` |
| Lint | `tflint` (plugin AWS) | Boas práticas e uso correto de recursos AWS |
| Testes unitários | Terratest (Go) | Sintaxe, tipos e estrutura do plano de execução |
| Cobertura | programa Go custom | Quais módulos têm testes de validate e plan |

Todos os testes são **unitários** — usam credenciais AWS mock e **nunca fazem chamadas reais à AWS**.

---

## Pré-requisitos

```bash
mise install   # instala terraform, terragrunt, go e tflint (versões em mise.toml)
```

Versões relevantes:

| Ferramenta | Versão |
|---|---|
| Terraform | >= 1.9.2 |
| Go | 1.22 |
| Terratest | v0.46.16 |
| tflint | latest |
| tflint-ruleset-aws | 0.35.0 |

---

## Linting

### Comandos

```bash
make lint          # executa fmt + tflint
make lint-fmt      # apenas terraform fmt -check
make lint-tflint   # apenas tflint
```

### Como funciona

**`terraform fmt -check -recursive atoms/ molecules/`**

Verifica se todos os arquivos `.tf` estão formatados corretamente. Não modifica arquivos — retorna erro se houver diferença. Para corrigir:

```bash
terraform fmt -recursive atoms/ molecules/
```

**`tflint`**

Analisa cada diretório que contenha arquivos `.tf` dentro de `atoms/aws/` e `molecules/aws/`. A configuração está em `.tflint.hcl`:

```hcl
plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Atoms não declaram required_providers nem required_version
# porque o Terragrunt os gera automaticamente
rule "terraform_required_providers" { enabled = false }
rule "terraform_required_version"   { enabled = false }
rule "terraform_typed_variables"    { enabled = false }
```

O tflint detecta problemas como variáveis declaradas mas não utilizadas (`terraform_unused_declarations`), tipos de instâncias inválidos, regiões AWS inexistentes, entre outros.

---

## Testes unitários

### Executar

```bash
make test-unit

# ou filtrando um teste específico:
cd tests && go test -tags=unit -v -run TestVpcValidate ./unit/...
cd tests && go test -tags=unit -v -run TestEcsTask ./unit/...
```

### Estrutura de arquivos

```
tests/
├── go.mod                      # módulo Go com Terratest v0.46.16
├── helpers/
│   └── terraform.go            # FixturePath() — resolve o caminho do fixture
├── fixtures/                   # fixtures Terraform (um por módulo)
│   ├── vpc/
│   │   ├── main.tf             # provider mock + module "vpc"
│   │   └── variables.tf        # variáveis com valores padrão para teste
│   ├── ecs_task/
│   ├── ecs_cluster/
│   ├── ec2/
│   ├── network_molecule/
│   └── k3s_extracted/          # gerado por scripts/extract-k3s-fixture.sh (gitignore)
└── unit/
    ├── setup_test.go           # TestMain — configuração global dos testes
    ├── vpc_test.go
    ├── ecs_task_test.go
    ├── ecs_cluster_test.go
    ├── ec2_test.go
    ├── network_molecule_test.go
    └── k3s_validate_test.go
```

### O que cada teste verifica

| Teste | Módulo testado | Tipo |
|---|---|---|
| `TestVpcValidate` | `atoms/aws/network/vpc` | Validate |
| `TestVpcPlanStructure` | `atoms/aws/network/vpc` | Plan |
| `TestEcsTaskValidate` | `atoms/aws/ecs/task` | Validate |
| `TestEcsTaskPlanResources` | `atoms/aws/ecs/task` | Plan |
| `TestEcsClusterValidate` | `atoms/aws/ecs/cluster` | Validate |
| `TestEcsClusterPlan` | `atoms/aws/ecs/cluster` | Plan |
| `TestEc2Validate` | `atoms/aws/ec2` | Validate |
| `TestNetworkMoleculeValidate` | `molecules/aws/network` | Validate |
| `TestNetworkMoleculePlan` | `molecules/aws/network` | Plan |
| `TestK3sOrganismValidate` | `organisms/aws/k3s/cluster` | Validate |
| `TestWireguardValidate` | `ec2/wireguard` (inline unit) | Validate |
| `TestWireguardPlan` | `ec2/wireguard` (inline unit) | Plan |

### Tipos de teste

**Validate** — verifica sintaxe HCL e tipos das variáveis (sem planejar recursos):

```go
func TestVpcValidate(t *testing.T) {
    t.Parallel()

    terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
        TerraformDir: helpers.FixturePath(t, "vpc"),
        NoColor:      true,
    })

    terraform.Init(t, terraformOptions)
    terraform.Validate(t, terraformOptions)
}
```

**Plan** — executa `terraform plan` e inspeciona os recursos planejados:

```go
func TestVpcPlanStructure(t *testing.T) {
    t.Parallel()

    terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
        TerraformDir: helpers.FixturePath(t, "vpc"),
        PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
        NoColor:      true,
    })

    plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

    vpcResource := plan.ResourcePlannedValuesMap["module.vpc.aws_vpc.main"]
    require.NotNil(t, vpcResource, "VPC resource should exist in plan")
    assert.Equal(t, "10.0.0.0/16", vpcResource.AttributeValues["cidr_block"])
}
```

### Fixtures

Cada fixture é um módulo Terraform mínimo que usa **credenciais mock** e aponta para o átomo/molécula real:

```hcl
provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true  # não valida credenciais
  skip_metadata_api_check     = true  # não acessa metadata da instância
  skip_requesting_account_id  = true  # não consulta account ID
  access_key                  = "mock"
  secret_key                  = "mock"
}

module "vpc" {
  source        = "../../../atoms/aws/network/vpc"
  vpc_cidr_block = var.vpc_cidr_block
  # ... demais variáveis obrigatórias
}
```

### Build tag

Todos os arquivos de teste contêm a tag `//go:build unit` na primeira linha. Isso garante que os testes só rodem quando explicitamente solicitados com `-tags=unit`:

```bash
go test -tags=unit ./unit/...   # roda os testes
go test ./unit/...               # não encontra nenhum teste
```

---

## Teste do K3s organism

O K3s usa Terragrunt com blocos `generate`, então o código Terraform fica inline no `terragrunt.hcl` — não existe arquivo `.tf` diretamente. O script `scripts/extract-k3s-fixture.sh` extrai esse código e cria um fixture standalone:

```bash
bash scripts/extract-k3s-fixture.sh
# gera tests/fixtures/k3s_extracted/ (gitignored)
```

O que o script faz:
1. Extrai o bloco `generate "provider"` → `provider.tf` (apenas o bloco `terraform {}`, sem o `provider "aws"`)
2. Extrai o bloco `generate "main"` → `main.tf` (injeta `locals { scripts_dir = "..." }` necessário para `templatefile`)
3. Cria `provider_override.tf` com o provider mock
4. Cria symlink `scripts/` apontando para os scripts do organism

Depois de gerar o fixture, o teste `TestK3sOrganismValidate` roda normalmente. Se o fixture não existir, o teste é pulado automaticamente.

---

## Relatório de cobertura

```bash
make coverage-report
# abre coverage.html no browser
```

O relatório mostra quais módulos têm testes e de que tipo:

- **Verde** — tem validate e plan
- **Amarelo** — tem apenas um dos dois
- **Vermelho** — sem nenhum teste

O código que gera o relatório está em `tests/cmd/coverage/main.go`. Ele:
1. Varre `atoms/`, `molecules/` e `organisms/` em busca de diretórios com arquivos `.tf`
2. Lê os `source = "..."` de cada fixture para mapear qual fixture testa qual módulo
3. Analisa os arquivos de teste para identificar chamadas a `terraform.Validate` e `InitAndPlanAndShowWithStruct`
4. Gera o HTML com filtros interativos por layer e status de cobertura

Estado atual da cobertura:

| Layer | Módulo | Validate | Plan |
|---|---|---|---|
| Atom | `aws/network/vpc` | ✓ | ✓ |
| Atom | `aws/ec2` | ✓ | — |
| Atom | `aws/ecs/cluster` | ✓ | ✓ |
| Atom | `aws/ecs/task` | ✓ | ✓ |
| Molecule | `aws/network` | ✓ | ✓ |
| Organism | `aws/k3s/cluster` | ✓ | — |
| Inline unit | `ec2/wireguard` | ✓ | ✓ |
| Atom | `aws/ecs/service` | — | — |
| Atom | `aws/eks` | — | — |
| Atom | `aws/cloud_map/*` | — | — |
| Atom | `cloudflare/*` | — | — |
| Atom | `gcp/*` | — | — |
| Atom | `oci/*` | — | — |

---

## Como criar um novo teste

### 1. Criar o fixture

```
tests/fixtures/<nome_do_modulo>/
├── main.tf       # provider mock + module block
└── variables.tf  # variáveis com defaults para teste
```

**`main.tf`** mínimo:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  access_key                  = "mock"
  secret_key                  = "mock"
}

module "meu_modulo" {
  source     = "../../../atoms/aws/meu_modulo"
  variavel_a = var.variavel_a
}
```

**`variables.tf`** com valores default para não precisar passar `-var` no teste:

```hcl
variable "variavel_a" {
  default = "valor-para-teste"
}
```

### 2. Criar o arquivo de teste

`tests/unit/meu_modulo_test.go`:

```go
//go:build unit

package unit

import (
    "path/filepath"
    "testing"

    "github.com/Vinny1892/infra-iac/tests/helpers"
    "github.com/gruntwork-io/terratest/modules/terraform"
    "github.com/stretchr/testify/require"
)

func TestMeuModuloValidate(t *testing.T) {
    t.Parallel()

    terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
        TerraformDir: helpers.FixturePath(t, "meu_modulo"),
        NoColor:      true,
    })

    terraform.Init(t, terraformOptions)
    terraform.Validate(t, terraformOptions)
}

func TestMeuModuloPlan(t *testing.T) {
    t.Parallel()

    terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
        TerraformDir: helpers.FixturePath(t, "meu_modulo"),
        PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
        NoColor:      true,
    })

    plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

    resource := plan.ResourcePlannedValuesMap["module.meu_modulo.aws_recurso.nome"]
    require.NotNil(t, resource, "recurso deve existir no plan")
}
```

### 3. Verificar

```bash
make test-unit
make coverage-report   # confirmar que o novo módulo aparece como coberto
```

---

## Troubleshooting

**`text file busy`** — acontecia em execuções paralelas quando múltiplos testes tentavam instalar o provider simultaneamente. Resolvido em `setup_test.go` removendo `TF_PLUGIN_CACHE_DIR` para que cada teste use seu próprio diretório temporário.

**`Invalid index` no plan** — ao usar recursos com `count = 0`, referências diretas como `resource[0].attr` falham no plano. Solução: usar `try(resource[0].attr, "")`.

**`Unsupported attribute` em variável com `default = {}`** — variáveis sem tipo definido com default de objeto vazio (`{}`) não permitem acesso a atributos. Solução: declarar o tipo explicitamente:
```hcl
variable "cloud_watch_configuration" {
  type = object({
    region  = string
    logName = string
  })
  default = { region = "", logName = "" }
}
```

**Fixture K3s não encontrado** — o fixture é gerado dinamicamente e está no `.gitignore`. Rode antes:
```bash
bash scripts/extract-k3s-fixture.sh
```
