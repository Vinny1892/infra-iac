# WireGuard VPN

Servidor WireGuard em EC2 com acesso via SSM Session Manager. Exposto via DNS Cloudflare em `wireguard.vinny.dev.br`.

## Arquitetura

- **EC2** `t3.micro` Ubuntu 22.04 LTS em subnet pública
- **SSM Session Manager** — sem SSH key exposta
- **Secrets Manager** — private key e public key do WireGuard persistidas
- **Cloudflare DNS** — `wireguard.vinny.dev.br` apontando para o IP público da instância
- **Split tunnel** — apenas tráfego da VPC `10.10.0.0/16` passa pelo WireGuard

## Bootstrapping da chave

Na primeira inicialização, o `user_data` (`scripts/init-wireguard.sh.tpl`):

1. Verifica se `wireguard/private-key` no Secrets Manager já tem valor
2. Se não tiver: gera com `wg genkey` e salva no SM
3. Se já existir: usa a chave existente
4. Deriva a public key e salva em `wireguard/public-key` no SM

Nas próximas reinicializações, a instância simplesmente lê a chave existente — o cliente nunca precisa ser reconfigurado.

## Deploy

```bash
cd aws/accounts/personal/us_east_1/applications/ec2/wireguard
terragrunt apply
```

## Recuperar a public key

```bash
aws secretsmanager get-secret-value \
  --secret-id wireguard/public-key \
  --query SecretString \
  --output text
```

## Configuração do cliente (split tunnel)

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address = 10.8.0.2/32

[Peer]
PublicKey = <wireguard/public-key do SM>
Endpoint = wireguard.vinny.dev.br:51820
AllowedIPs = 10.10.0.0/16
PersistentKeepalive = 25
```

> `AllowedIPs = 10.10.0.0/16` garante split tunnel: apenas tráfego destinado à VPC passa pelo WireGuard.

## Adicionar peers

Após conectar via SSM na instância:

```bash
aws ssm start-session --target <wireguard_instance_id>

# Gerar chave do cliente (no cliente)
wg genkey | tee privatekey | wg pubkey > publickey

# Adicionar peer no servidor
sudo wg set wg0 peer <CLIENT_PUBLIC_KEY> allowed-ips 10.8.0.X/32

# Salvar configuração
sudo wg-quick save wg0
```

## Verificar status

```bash
aws ssm start-session --target <wireguard_instance_id>
sudo wg show
```
