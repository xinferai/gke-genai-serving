# One node pool: a group of identical VMs (the AWS equivalent is an EKS managed node group).

variable "name" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "location" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "min_nodes" {
  type = number
}

variable "max_nodes" {
  type = number
}

variable "spot" {
  description = "Spot VMs cost much less, and Google can reclaim them at any time."
  type        = bool
}

variable "service_account" {
  type = string
}

variable "labels" {
  type = map(string)
}

variable "taints" {
  description = "Pods without a matching toleration are kept off this pool."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "disk_size_gb" {
  description = "Boot disk per node. Container images live here, and GPU images are large."
  type        = number
  default     = 30
}

variable "gpu" {
  description = "One GPU type per node, for example { type = \"nvidia-l4\", count = 1 }. Null for CPU pools."
  type = object({
    type  = string
    count = number
  })
  default = null
}

resource "google_container_node_pool" "this" {
  name     = var.name
  cluster  = var.cluster_id
  location = var.location

  initial_node_count = var.min_nodes

  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Upgrades add one new node before draining an old one, so capacity never drops.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    disk_type       = "pd-balanced"
    disk_size_gb    = var.disk_size_gb
    service_account = var.service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = var.labels

    # GKE installs the NVIDIA driver itself, and taints GPU nodes
    # (nvidia.com/gpu=present:NoSchedule) so only pods that ask for a GPU land there.
    dynamic "guest_accelerator" {
      for_each = var.gpu == null ? [] : [var.gpu]
      content {
        type  = guest_accelerator.value.type
        count = guest_accelerator.value.count
        gpu_driver_installation_config {
          gpu_driver_version = "LATEST"
        }
      }
    }

    dynamic "taint" {
      for_each = var.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    # Pods see GKE's metadata server, which hands out Workload Identity tokens and
    # hides the node's own credentials from them.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  # GKE manages the node count once the autoscaler runs.
  lifecycle {
    ignore_changes = [initial_node_count]
  }
}
