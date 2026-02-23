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
  project = local.project
  region  = "us-central1"
}

provider "kubernetes" {
  host                   = "https://${module.cluster_gke.endpoint}"
  cluster_ca_certificate = base64decode(module.cluster_gke.ca_certificate)
  token                  = module.cluster_gke.token
}