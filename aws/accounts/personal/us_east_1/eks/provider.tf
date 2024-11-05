terraform {
  required_version = ">= v1.9.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
  profile = "sandim-account"
  default_tags {
    tags = {
      managed_by = "terraform"
      environment = "testing"
      account = "personal"
    }
  }
}