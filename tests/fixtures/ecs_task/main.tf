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

module "ecs_task" {
  source       = "../../../atoms/aws/ecs/task"
  task_name    = var.task_name
  docker_image = var.docker_image
  family       = var.family
  secrets      = var.secrets
  subnet_id    = var.subnet_id
}
