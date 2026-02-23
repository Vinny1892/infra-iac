
locals {
  project = "engaged-proxy-273800"
}



resource "google_service_account" "default" {
  account_id   = "gke-service-account"
  display_name = "gke service account"
}

module "cluster_gke" {
  source                = "../../../../modules/gke"
  cluster_name          = "gke-test-cluster"
  location              = "us-central1-a"
  network               = google_compute_network.vpc_network.self_link
  number_of_nodes       = 3
  service_account_email = google_service_account.default.email
  subnetwork            = google_compute_subnetwork.subnet.self_link
  project               = local.project
  machine_type = "e2-medium"
}