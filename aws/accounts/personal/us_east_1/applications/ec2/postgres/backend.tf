terraform {
  backend "s3" {
    bucket         = "infra-terraform-state-seila"
    key            = "aws/account/personal/us_east_1/applications/ec2/postgres"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-terraform-lock-table"
  }
}