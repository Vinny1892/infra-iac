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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
EOF
}

locals {
  scripts_dir = "${get_repo_root()}/organisms/aws/k3s/cluster/scripts"
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "k3s_token" {
  type      = string
  sensitive = true
  default   = "k3s-seila"
}

variable "masters_count" {
  type    = number
  default = 2
}

variable "rds_password" {
  type      = string
  sensitive = true
  default   = "password"
}

locals {
  cluster_dns_name = aws_lb.k3s_api_nlb.dns_name
  oidc_bucket_name = "k3s-oidc-$${data.aws_caller_identity.current.account_id}"
  oidc_issuer_url  = "https://$${aws_s3_bucket.oidc.bucket_regional_domain_name}"
}

data "aws_caller_identity" "current" {}

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "k3s_sg" {
  name_prefix = "k3s-cluster-"
  description = "K3s cluster security group"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k3s-cluster-sg"
  }
}

resource "aws_security_group" "database_sg" {
  name_prefix = "k3s-database-"
  description = "K3s RDS security group"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k3s-database-sg"
  }
}

# =============================================================================
# IAM - Node Role
# =============================================================================

resource "aws_iam_role" "k3s_node_role" {
  name = "k3s-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.k3s_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "k3s_ssm_kubeconfig" {
  name = "k3s-ssm-kubeconfig"
  role = aws_iam_role.k3s_node_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:PutParameter", "ssm:GetParameter"]
      Resource = "arn:aws:ssm:us-east-1:$${data.aws_caller_identity.current.account_id}:parameter/k3s/*"
    }]
  })
}

resource "aws_iam_role_policy" "k3s_s3_oidc" {
  name = "k3s-s3-oidc-upload"
  role = aws_iam_role.k3s_node_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:PutObjectAcl"]
      Resource = "$${aws_s3_bucket.oidc.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "k3s_node_profile" {
  name = "k3s-node-instance-profile"
  role = aws_iam_role.k3s_node_role.name
}

# =============================================================================
# IRSA - S3 Bucket for OIDC Discovery
# =============================================================================

resource "aws_s3_bucket" "oidc" {
  bucket        = local.oidc_bucket_name
  force_destroy = true

  tags = {
    Name = "k3s-oidc-discovery"
  }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket                  = aws_s3_bucket.oidc.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "oidc_public_read" {
  bucket     = aws_s3_bucket.oidc.id
  depends_on = [aws_s3_bucket_public_access_block.oidc]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "$${aws_s3_bucket.oidc.arn}/*"
    }]
  })
}

resource "aws_s3_object" "oidc_discovery" {
  bucket       = aws_s3_bucket.oidc.id
  key          = ".well-known/openid-configuration"
  content_type = "application/json"
  content = jsonencode({
    issuer                                = local.oidc_issuer_url
    jwks_uri                              = "$${local.oidc_issuer_url}/openid/v1/jwks"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })
}

# =============================================================================
# IRSA - IAM OIDC Provider
# =============================================================================

data "tls_certificate" "oidc" {
  url = local.oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "k3s" {
  url             = local.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# =============================================================================
# IRSA - IAM Roles for Service Accounts
# =============================================================================

resource "aws_iam_role" "aws_lb_controller" {
  name = "k3s-aws-lb-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.k3s.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "$${replace(aws_iam_openid_connect_provider.k3s.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "$${replace(aws_iam_openid_connect_provider.k3s.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "aws_lb_controller" {
  name = "k3s-aws-lb-controller-policy"
  role = aws_iam_role.aws_lb_controller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:DescribeCoipPools",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeRouteTables",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSecurityGroup" }
          Null         = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:DeleteSecurityGroup"]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
        Resource = "*"
        Condition = {
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes"
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
          }
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:ModifyListenerAttributes"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "argocd" {
  name = "k3s-argocd"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.k3s.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "$${replace(aws_iam_openid_connect_provider.k3s.url, "https://", "")}:sub" = "system:serviceaccount:argocd:argocd-server"
          "$${replace(aws_iam_openid_connect_provider.k3s.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# =============================================================================
# RDS PostgreSQL (K3s HA Datastore)
# =============================================================================

resource "aws_db_subnet_group" "k3s" {
  name       = "k3s-subnet-group"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "k3s_rds" {
  identifier             = "k3s-db"
  allocated_storage      = 20
  engine                 = "postgres"
  instance_class         = "db.t3.micro"
  username               = "k3sadmin"
  password               = var.rds_password
  db_subnet_group_name   = aws_db_subnet_group.k3s.name
  skip_final_snapshot    = true
  db_name                = "k3s"
  vpc_security_group_ids = [aws_security_group.database_sg.id]

  tags = {
    Name = "k3s-datastore"
  }
}

# =============================================================================
# Launch Template
# =============================================================================

resource "aws_launch_template" "k3s_master" {
  name          = "k3s-master-lt"
  image_id      = "ami-01816d07b1128cd2d"
  instance_type = "t2.medium"

  vpc_security_group_ids = [aws_security_group.k3s_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.k3s_node_profile.name
  }

  user_data = base64encode(templatefile("${local.scripts_dir}/init-master.tfpl", {
    token         = var.k3s_token
    username      = aws_db_instance.k3s_rds.username
    password      = aws_db_instance.k3s_rds.password
    hostname      = aws_db_instance.k3s_rds.address
    port          = aws_db_instance.k3s_rds.port
    database_name = aws_db_instance.k3s_rds.db_name
    dns_name      = local.cluster_dns_name
    oidc_bucket   = aws_s3_bucket.oidc.bucket
  }))

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "k3s-master"
    }
  }
}

# =============================================================================
# Auto Scaling Group
# =============================================================================

resource "aws_autoscaling_group" "k3s_masters" {
  name             = "k3s-masters"
  min_size         = var.masters_count
  max_size         = var.masters_count
  desired_capacity = var.masters_count

  vpc_zone_identifier = var.public_subnet_ids

  launch_template {
    id      = aws_launch_template.k3s_master.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "k3s-master"
    propagate_at_launch = true
  }
}

# =============================================================================
# NLB - K3s API
# =============================================================================

resource "aws_lb" "k3s_api_nlb" {
  name               = "k3s-api-nlb"
  internal           = false
  load_balancer_type = "network"

  dynamic "subnet_mapping" {
    for_each = var.public_subnet_ids
    content {
      subnet_id = subnet_mapping.value
    }
  }

  tags = {
    Name = "k3s-api-nlb"
  }
}

resource "aws_lb_target_group" "k3s_api" {
  name     = "k3s-api-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = var.vpc_id

  health_check {
    protocol            = "TCP"
    port                = 6443
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "k3s_api" {
  load_balancer_arn = aws_lb.k3s_api_nlb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k3s_api.arn
  }
}

resource "aws_autoscaling_attachment" "k3s_api" {
  autoscaling_group_name = aws_autoscaling_group.k3s_masters.name
  lb_target_group_arn    = aws_lb_target_group.k3s_api.arn
}

# =============================================================================
# Outputs
# =============================================================================

output "nlb_dns_name" {
  value = aws_lb.k3s_api_nlb.dns_name
}

output "cluster_endpoint" {
  value = "https://$${aws_lb.k3s_api_nlb.dns_name}:6443"
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.k3s.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.k3s.url
}

output "aws_lb_controller_role_arn" {
  value = aws_iam_role.aws_lb_controller.arn
}

output "argocd_role_arn" {
  value = aws_iam_role.argocd.arn
}

output "vpc_id" {
  value = var.vpc_id
}
EOF
}
