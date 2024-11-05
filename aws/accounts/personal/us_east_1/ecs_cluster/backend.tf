terraform {
  backend "s3" {
    profile = "personal"
    bucket         = "infra-terraform-state-seila"
    key            = "aws/account/personal/ecs_cluster/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-terraform-lock-table"
  }
}