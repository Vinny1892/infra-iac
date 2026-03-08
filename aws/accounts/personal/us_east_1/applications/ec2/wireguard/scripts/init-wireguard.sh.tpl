#!/bin/bash
set -euo pipefail

# IMDSv2 token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region")

# Install WireGuard
apt-get update -y
apt-get install -y wireguard awscli

# Bootstrap private key from Secrets Manager
EXISTING=$(aws secretsmanager get-secret-value \
  --secret-id "${private_key_secret_arn}" \
  --region "$REGION" \
  --query SecretString \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING" ]; then
  PRIVATE_KEY=$(wg genkey)
  aws secretsmanager put-secret-value \
    --secret-id "${private_key_secret_arn}" \
    --region "$REGION" \
    --secret-string "$PRIVATE_KEY"
else
  PRIVATE_KEY="$EXISTING"
fi

PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

# Save public key to Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id "${public_key_secret_arn}" \
  --region "$REGION" \
  --secret-string "$PUBLIC_KEY"

# Detect default network interface
IFACE=$(ip route | grep default | awk '{print $5}')

# Configure WireGuard
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $PRIVATE_KEY
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
WGEOF

chmod 600 /etc/wireguard/wg0.conf

# Enable IP forwarding
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -w net.ipv4.ip_forward=1

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
