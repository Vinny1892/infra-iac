locals {
  default_bucket         = "infra-terraform-state-seila"
  default_region         = "us-east-1"
  default_dynamodb_table = "infra-terraform-lock-table"
  default_profile        = "personal"
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    profile        = local.default_profile
    bucket         = local.default_bucket
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.default_region
    encrypt        = true
    dynamodb_table = local.default_dynamodb_table
  }
}
