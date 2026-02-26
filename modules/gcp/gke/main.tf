data "google_client_config" "default" {}


resource "google_container_cluster" "cluster" {
  name     = var.cluster_name
  location = var.location
  deletion_protection = false

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }
  private_cluster_config {
    enable_private_endpoint = false
    enable_private_nodes = false
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  network = var.network
  subnetwork = var.subnetwork
}


resource "google_container_node_pool" "primary_preemptible_nodes" {
  name       = "${var.cluster_name}-node-pool"
  location   = var.location
  cluster    = google_container_cluster.cluster.id
  node_count = var.number_of_nodes

  node_config {
    preemptible   = var.preemptible
    machine_type  = var.machine_type
    image_type    = "COS_CONTAINERD" # ou "UBUNTU_CONTAINERD", "COS", etc.
    service_account = var.service_account_email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

}


### External Secret Setup

# Criação da Service Account
resource "google_service_account" "external_secrets_sa" {
  account_id   = "external-secrets-sa"
  display_name = "External Secrets Service Account for cluster ${var.cluster_name}"
}

# Binding da role de Secret Manager à Service Account
resource "google_project_iam_member" "secretmanager_accessor" {
  project = var.project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets_sa.email}"
}

resource "google_project_iam_member" "token_creator" {
  project = var.project
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.external_secrets_sa.email}"
}