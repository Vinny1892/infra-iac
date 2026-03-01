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

module "ec2" {
  source             = "../../../atoms/aws/ec2"
  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids
  instance_name      = var.instance_name
}
