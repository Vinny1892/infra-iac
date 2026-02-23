terraform {
  backend "s3" {
    profile        = "personal"
    bucket         = "infra-terraform-state-seila"
    key            = "oci/tenancy/regulus/us_ashburn_1/applications/compute/vm/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-terraform-lock-table"
  }
}
