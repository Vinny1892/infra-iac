include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Override provider: shared-services account tags
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = "v1.9.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      managed_by  = "terraform"
      environment = "production"
      account     = "shared-services"
    }
  }
}
EOF
}

dependency "ecs_cluster" {
  config_path = "../../../../ecs_cluster"

  mock_outputs = {
    cluster_id = "arn:aws:ecs:us-east-1:000000000000:cluster/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "vpc" {
  config_path = "../../../../network/vpc"

  mock_outputs = {
    vpc_id = "vpc-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "internal_domain" {
  config_path = "../../../../internal_domain"

  mock_outputs = {
    namespace_id = "ns-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "../../../../../../../../molecules/aws/ecs/app"
}

inputs = {
  # Service (shared-services account — valores hardcoded)
  service_name    = "loki-staging"
  app_replicas    = 1
  cluster_name    = "infratools_cluster"
  vpc_id          = "vpc-0c679f53639c92df2"
  security_groups = ["sg-0307995ed6e09f739"]
  subnets         = ["subnet-06dc6a37ecd9bd3c4", "subnet-02615695f8c4c58ce"]
  dns_app_name    = "loki-staging"
  namespace_name  = "principia-shared-services.internal"

  # Task
  task_name          = "loki-staging"
  docker_image       = "207498280574.dkr.ecr.us-east-1.amazonaws.com/platform-watch-stack/loki"
  family             = "loki-staging"
  secrets            = []
  resources          = { cpu = 256, memory = 512 }
  port_mapping       = [{ containerPort = 3100, hostPort = 3100 }]
  subnet_id          = "subnet-06dc6a37ecd9bd3c4"
  enable_efs         = true
  enable_cloud_watch = true
  cloud_watch_configuration = {
    logName = "/org/principia/loki-staging"
    region  = "us-east-1"
  }
  health_check_task = {
    healthCheck = {
      retries     = 3
      command     = ["CMD-SHELL", "curl -f http://localhost:3100/ready || exit 0"]
      timeout     = 5
      interval    = 30
      startPeriod = null
    }
  }
  efs_configuration = {
    transition_to_ia = "AFTER_30_DAYS"
    root_directory   = "/loki"
    mount_point = [{
      sourceVolume  = "efs-loki"
      containerPath = "/loki"
      readOnly      = false
    }]
  }
}
