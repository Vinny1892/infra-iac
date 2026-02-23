terraform {
  backend "s3" {
    profile = "personal"
    bucket         = "infra-terraform-state-seila"
    key            = "aws/account/personal/us_east_1/applications/ec2/openclaw"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "infra-terraform-lock-table"
  }
}