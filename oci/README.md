# OCI (Oracle Cloud Infrastructure)

## Pré-requisitos

### 1. Instalar o OCI CLI

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

### 2. Configurar credenciais

Execute o setup interativo:

```bash
oci setup config
```

Isso cria o arquivo `~/.oci/config` com o seguinte formato:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaaaaa...
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=ocid1.tenancy.oc1..aaaaaaa...
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
```

O provider Terraform OCI lê automaticamente de `~/.oci/config` (profile DEFAULT).

### Alternativa: Variáveis de ambiente

Caso prefira não usar o config file, exporte as variáveis:

```bash
export TF_VAR_compartment_id="ocid1.compartment.oc1..aaaaaaa..."

# Autenticação do provider (alternativa ao ~/.oci/config)
export OCI_TENANCY_OCID="ocid1.tenancy.oc1..aaaaaaa..."
export OCI_USER_OCID="ocid1.user.oc1..aaaaaaa..."
export OCI_FINGERPRINT="aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
export OCI_PRIVATE_KEY_PATH="~/.oci/oci_api_key.pem"
export OCI_REGION="us-ashburn-1"
```

## Variáveis obrigatórias

| Variável | Descrição | Como obter |
|---|---|---|
| `compartment_id` | OCID do compartment | Console OCI > Identity > Compartments |
| `image_id` (para VM) | OCID da imagem do SO | Console OCI > Compute > Custom Images, ou use `oci compute image list` |

### Descobrir o compartment_id

```bash
oci iam compartment list --compartment-id-in-subtree true --query 'data[].{name:name, id:id}' --output table
```

### Descobrir imagens disponíveis (Oracle Linux ARM para Always Free)

```bash
oci compute image list \
  --compartment-id <compartment_id> \
  --operating-system "Oracle Linux" \
  --shape "VM.Standard.A1.Flex" \
  --query 'data[].{name:"display-name", id:id}' \
  --output table
```

### Descobrir Availability Domains

```bash
oci iam availability-domain list --query 'data[].{name:name}' --output table
```

Os nomes retornados (ex: `vSbr:US-ASHBURN-AD-1`) devem ser usados na variável `availability_domains` do módulo de rede.

## Ordem de apply

1. **Network/VCN** — rede virtual, subnets, gateways
2. **Applications** — instâncias compute

## Comandos

### Network

```bash
# Inicializar
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/network/vcn init

# Planejar
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/network/vcn plan \
  -var="compartment_id=<COMPARTMENT_OCID>"

# Aplicar
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/network/vcn apply \
  -var="compartment_id=<COMPARTMENT_OCID>"
```

### Compute VM

```bash
# Inicializar
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/applications/compute/vm init

# Planejar
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/applications/compute/vm plan \
  -var="compartment_id=<COMPARTMENT_OCID>" \
  -var="image_id=<IMAGE_OCID>"

# Aplicar
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/applications/compute/vm apply \
  -var="compartment_id=<COMPARTMENT_OCID>" \
  -var="image_id=<IMAGE_OCID>"
```

### Destruir (ordem reversa)

```bash
terraform -chdir=oci/tenancies/regulus/us_ashburn_1/applications/compute/vm destroy \
  -var="compartment_id=<COMPARTMENT_OCID>" \
  -var="image_id=<IMAGE_OCID>"

terraform -chdir=oci/tenancies/regulus/us_ashburn_1/network/vcn destroy \
  -var="compartment_id=<COMPARTMENT_OCID>"
```

## Estrutura de módulos

```
oci/
├── modules/
│   ├── network/vcn/         # VCN, subnets, IGW, NAT, route tables, security list
│   └── compute/instance/    # Instância OCI (VM.Standard.A1.Flex por padrão)
└── tenancies/
    └── regulus/us_ashburn_1/
        ├── network/vcn/             # Instância concreta da rede
        └── applications/compute/vm/ # Instância concreta da VM
```

## Always Free Tier

O shape padrão `VM.Standard.A1.Flex` (ARM Ampere) faz parte do Always Free tier da OCI:
- Até **4 OCPUs** e **24 GB RAM** gratuitos (podem ser divididos em múltiplas instâncias)
- A configuração padrão usa 1 OCPU e 6 GB RAM

## Backend

O state do Terraform é armazenado no mesmo bucket S3 da AWS (`infra-terraform-state-seila`), com keys no padrão:
```
oci/tenancy/regulus/us_ashburn_1/{componente}/terraform.tfstate
```
