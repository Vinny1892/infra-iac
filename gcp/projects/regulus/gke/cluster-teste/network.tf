# Criação da VPC
resource "google_compute_network" "vpc_network" {
  name                    = "vpc-gke"
  auto_create_subnetworks = false
}

# Sub-rede associada à VPCgke
resource "google_compute_subnetwork" "subnet" {
  name          = "my-subnet"
  ip_cidr_range = "10.50.0.0/24"
  region        = "us-central1"
  network       = google_compute_network.vpc_network.self_link
}