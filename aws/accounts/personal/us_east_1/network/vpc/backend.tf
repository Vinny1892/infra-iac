terraform {
  backend "s3" {
    bucket         = "infra-terraform-state-seila"
    key            = "aws/account/personal/network/vpc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-terraform-lock-table"
  }
}