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

# ─── Secrets Manager ────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "wireguard_private_key" {
  name                    = "wireguard/private-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "wireguard_public_key" {
  name                    = "wireguard/public-key"
  recovery_window_in_days = 0
}

# ─── IAM ────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "wireguard_role" {
  name = "wireguard-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.wireguard_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "wireguard_sm" {
  name = "wireguard-secrets-manager"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue"
      ]
      Resource = [
        aws_secretsmanager_secret.wireguard_private_key.arn,
        aws_secretsmanager_secret.wireguard_public_key.arn
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "wireguard_sm" {
  role       = aws_iam_role.wireguard_role.name
  policy_arn = aws_iam_policy.wireguard_sm.arn
}

resource "aws_iam_instance_profile" "wireguard" {
  name = "wireguard-instance-profile"
  role = aws_iam_role.wireguard_role.name
}

# ─── Security Group ──────────────────────────────────────────────────────────

resource "aws_security_group" "wireguard_sg" {
  name   = "wireguard-sg"
  vpc_id = var.vpc_id

  ingress {
    description = "WireGuard UDP"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── EC2 Instance ────────────────────────────────────────────────────────────

resource "aws_instance" "wireguard" {
  ami                         = "ami-01816d07b1128cd2d"
  instance_type               = "t3.micro"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.wireguard_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.wireguard.name
  associate_public_ip_address = true

  # user_data simplificado no fixture (sem templatefile) para não depender de arquivo externo
  user_data = base64encode("#!/bin/bash\necho 'wireguard fixture placeholder'")

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "wireguard"
  }
}

# Nota: module "dns_record" (Cloudflare) omitido do fixture.
# O provider Cloudflare não suporta credenciais mock para plan.
# O atom cloudflare/domain é testado separadamente.
