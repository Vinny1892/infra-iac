terraform {
  backend "s3" {
    bucket         = "infra-iac-terraform-state"
    key            = "aws/account/shared_services/applications/ecs/loki/production/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-iac-terraform-state"
  }
}