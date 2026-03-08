include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Override provider: needs both AWS and Cloudflare
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = ">= v1.9.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.41.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      managed_by  = "terraform"
      environment = "testing"
      account     = "personal"
    }
  }
}

provider "cloudflare" {}
EOF
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "subnet_id" {}
variable "vpc_id" {}
variable "cloudflare_zone_id" { default = "" }

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
  ami                         = "ami-01816d07b1128cd2d" # Ubuntu 22.04 LTS us-east-1
  instance_type               = "t3.micro"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.wireguard_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.wireguard.name
  associate_public_ip_address = true

  user_data = base64encode(templatefile("$${path.module}/scripts/init-wireguard.sh.tpl", {
    private_key_secret_arn = aws_secretsmanager_secret.wireguard_private_key.arn
    public_key_secret_arn  = aws_secretsmanager_secret.wireguard_public_key.arn
  }))

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "wireguard"
  }
}

# ─── Cloudflare DNS ──────────────────────────────────────────────────────────

module "dns_record" {
  source = "../../../../../../atoms/cloudflare/domain"
  dns = {
    name    = "wireguard.vinny.dev.br"
    content = aws_instance.wireguard.public_ip
    type    = "A"
  }
  cloudflare_zone_id = var.cloudflare_zone_id
  proxiable          = false
}

# ─── Outputs ─────────────────────────────────────────────────────────────────

output "wireguard_public_ip" {
  value = aws_instance.wireguard.public_ip
}

output "wireguard_dns" {
  value = "wireguard.vinny.dev.br"
}

output "wireguard_instance_id" {
  value = aws_instance.wireguard.id
}

output "private_key_secret_arn" {
  value = aws_secretsmanager_secret.wireguard_private_key.arn
}

output "public_key_secret_arn" {
  value = aws_secretsmanager_secret.wireguard_public_key.arn
}
EOF
}

dependency "vpc" {
  config_path = "../../../network/vpc"

  mock_outputs = {
    vpc_id        = "vpc-mock"
    subnet_public = [{ id = "subnet-mock" }]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  subnet_id          = dependency.vpc.outputs.subnet_public[0].id
  vpc_id             = dependency.vpc.outputs.vpc_id
  cloudflare_zone_id = ""
}
