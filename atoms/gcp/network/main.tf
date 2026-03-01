# Criação da VPC
resource "google_compute_network" "vpc_network" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

# Sub-rede associada à VPCgke
resource "google_compute_subnetwork" "subnet" {
  for_each      = var.subnets
  name          = each.value.name
  ip_cidr_range = each.value.cidr
  region        = each.value.region
  network       = google_compute_network.vpc_network.self_link
}