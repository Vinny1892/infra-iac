include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../organisms/gcp/gke/cluster"
}

# google provider + kubernetes provider (references module.cluster_gke outputs in cache)
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_version = "v1.9.2"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.32.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.15.0"
    }
  }
}

provider "google" {
  project = "engaged-proxy-273800"
  region  = "us-central1"
}

provider "kubernetes" {
  host                   = "https://$${module.cluster_gke.endpoint}"
  cluster_ca_certificate = base64decode(module.cluster_gke.ca_certificate)
  token                  = module.cluster_gke.token
}
EOF
}

inputs = {
  project         = "engaged-proxy-273800"
  region          = "us-central1"
  cluster_name    = "gke-test-cluster"
  location        = "us-central1-a"
  network_name    = "vpc-gke"
  subnet_name     = "my-subnet"
  subnet_cidr     = "10.50.0.0/24"
  number_of_nodes = 3
  machine_type    = "e2-medium"
}
