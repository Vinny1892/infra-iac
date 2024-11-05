terraform {
  backend "s3" {
    profile = "personal"
    bucket         = "infra-terraform-state-seila"
    key            = "aws/account/personal/applications/ecs/apache_superset/staging/application/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-terraform-lock-table"
  }
}