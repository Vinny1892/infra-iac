include "root" {
  path = find_in_parent_folders("root.hcl")
}

# Override provider: needs google + kubernetes + helm required_providers
# kubernetes provider configured in generate "main" (depends on module output)
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
EOF
}

generate "main" {
  path      = "main.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
locals {
  project = "engaged-proxy-273800"
}

resource "google_compute_network" "vpc_network" {
  name                    = "vpc-gke"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "my-subnet"
  ip_cidr_range = "10.50.0.0/24"
  region        = "us-central1"
  network       = google_compute_network.vpc_network.self_link
}

resource "google_service_account" "default" {
  account_id   = "gke-service-account"
  display_name = "gke service account"
}

module "cluster_gke" {
  source                = "../../../../../modules/gcp/gke"
  cluster_name          = "gke-test-cluster"
  location              = "us-central1-a"
  network               = google_compute_network.vpc_network.self_link
  number_of_nodes       = 3
  service_account_email = google_service_account.default.email
  subnetwork            = google_compute_subnetwork.subnet.self_link
  project               = local.project
  machine_type          = "e2-medium"
}

provider "kubernetes" {
  host                   = "https://$${module.cluster_gke.endpoint}"
  cluster_ca_certificate = base64decode(module.cluster_gke.ca_certificate)
  token                  = module.cluster_gke.token
}
EOF
}
