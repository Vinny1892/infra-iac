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
