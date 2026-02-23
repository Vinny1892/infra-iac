terraform {
  required_version = ">= v1.9.2"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  region = "us-ashburn-1"
}
