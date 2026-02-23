terraform {
  required_version = ">= v1.9.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
      version = "4.41.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      managed_by = "terraform"
      environment = "testing"
      account = "personal"
    }
  }
}

