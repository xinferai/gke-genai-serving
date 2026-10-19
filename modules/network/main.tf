# A custom-mode VPC with one subnet. GKE runs "VPC-native": pods and services take their
# IPs from two secondary ranges on the subnet, so they are routable inside the VPC.
# A GCP VPC is global (subnets are regional); an AWS VPC is regional.

variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "nodes_cidr" {
  type = string
}

variable "pods_cidr" {
  description = "Sets the cluster's size ceiling: each node reserves a /24 from it by default."
  type        = string
}

variable "services_cidr" {
  type = string
}

resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name}-${var.region}"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.nodes_cidr

  # Private nodes have no public IP; this lets them reach Google APIs anyway.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Cloud NAT gives the private nodes outbound internet (pulling public images, for
# example) without giving them public IPs. The AWS equivalent is a NAT gateway.
resource "google_compute_router" "this" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

output "network_id" {
  value = google_compute_network.this.id
}

output "subnet_id" {
  value = google_compute_subnetwork.this.id
}

output "pods_range_name" {
  value = "pods"
}

output "services_range_name" {
  value = "services"
}
