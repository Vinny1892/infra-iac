resource "google_compute_network" "vpc_network" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc_network.self_link
}

resource "google_service_account" "default" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
}

module "cluster_gke" {
  source                = "../../../atoms/gcp/gke"
  cluster_name          = var.cluster_name
  location              = var.location
  network               = google_compute_network.vpc_network.self_link
  number_of_nodes       = var.number_of_nodes
  service_account_email = google_service_account.default.email
  subnetwork            = google_compute_subnetwork.subnet.self_link
  project               = var.project
  machine_type          = var.machine_type
}
