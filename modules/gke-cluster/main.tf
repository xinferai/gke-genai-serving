# A GKE Standard cluster (you manage node pools; Autopilot would manage them for you).
# The default node pool is removed so every pool is its own Terraform resource:
# changing a pool then never forces the cluster itself to be replaced.

variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "location" {
  description = "A zone gives a zonal cluster (one control plane); a region gives a regional one."
  type        = string
}

variable "network_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "admin_cidr" {
  type = string
}

resource "google_container_cluster" "this" {
  name     = var.name
  location = var.location

  network    = var.network_id
  subnetwork = var.subnet_id

  remove_default_node_pool = true
  initial_node_count       = 1

  # A lab must be destroyable. In production this stays true.
  deletion_protection = false

  # GKE upgrades the control plane and nodes on this channel's schedule.
  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Nodes get no public IPs. The control plane keeps a public endpoint, but only
  # admin_cidr may reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.admin_cidr
      display_name = "admin"
    }
  }

  # Workload Identity: a pod's Kubernetes service account can act as a Google
  # service account, with no key files. The AWS equivalent is IRSA / EKS Pod Identity.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Dataplane V2 (eBPF). It enforces Kubernetes network policies, needed in session 2.
  datapath_provider = "ADVANCED_DATAPATH"

  # Gateway API: a Gateway object in the cluster makes GKE build a Google Cloud load
  # balancer. The AWS equivalent is the AWS Load Balancer Controller.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }
}

output "id" {
  value = google_container_cluster.this.id
}

output "name" {
  value = google_container_cluster.this.name
}

output "location" {
  value = google_container_cluster.this.location
}
