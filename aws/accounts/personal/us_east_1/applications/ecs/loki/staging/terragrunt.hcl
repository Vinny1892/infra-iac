include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Override provider: shared-services tags
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

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
data "aws_ecs_cluster" "cluster" {
  cluster_name = "infratools_cluster"
}

data "aws_vpc" "vpc" {
  id = "vpc-0c679f53639c92df2"
}

data "aws_service_discovery_dns_namespace" "internal_dns" {
  name = "principia-shared-services.internal"
  type = "DNS_PRIVATE"
}

data "aws_subnet" "selected" {
  id = "subnet-06dc6a37ecd9bd3c4"
}

module "staging_loki" {
  source                   = "../../../../../../../../modules/aws/ecs/service"
  app_replicas             = 1
  cluster_id               = data.aws_ecs_cluster.cluster.id
  enable_lb                = false
  assign_lb_with_cloud_map = false
  internal_dns = {
    dns_app_name = "loki-staging"
    dns_id       = data.aws_service_discovery_dns_namespace.internal_dns.id
  }
  vpc_id          = data.aws_vpc.vpc.id
  service_name    = "loki-staging"
  task_arn        = module.task.task_arn
  security_groups = ["sg-0307995ed6e09f739"]
  subnets         = ["subnet-06dc6a37ecd9bd3c4", "subnet-02615695f8c4c58ce"]
  depends_on      = [module.task]
}

module "task" {
  source       = "../../../../../../../../modules/aws/ecs/task"
  docker_image = "207498280574.dkr.ecr.us-east-1.amazonaws.com/platform-watch-stack/loki"
  family       = "loki-staging"
  secrets      = []
  resources = {
    cpu    = 256
    memory = 512
  }
  port_mapping = [{
    containerPort : 3100
    hostPort : 3100
  }]
  task_name          = "loki-staging"
  enable_efs         = true
  enable_cloud_watch = true
  cloud_watch_configuration = {
    logName = "/org/principia/loki-staging"
    region  = "us-east-1"
  }
  subnet_id = data.aws_subnet.selected.id
  health_check_task = {
    "healthCheck" : {
      "retries" : 3,
      "command" : [
        "CMD-SHELL",
        "curl -f http://localhost:3100/ready || exit 0"
      ],
      "timeout" : 5,
      "interval" : 30,
      "startPeriod" : null
    },
  }
  efs_configuration = {
    transition_to_ia = "AFTER_30_DAYS"
    root_directory   = "/loki"
    mount_point = [{
      "sourceVolume" : "efs-loki",
      "containerPath" : "/loki",
      "readOnly" : false
    }]
  }
}
EOF
}
