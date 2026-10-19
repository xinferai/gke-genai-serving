# One environment's network, node service account, cluster and node pools. Called by
# envs/<env>/cluster with the environment's project; everything else is the same in every
# environment.

module "network" {
  source = "../network"

  name          = "lab"
  region        = var.region
  nodes_cidr    = "10.10.0.0/20"
  pods_cidr     = "10.20.0.0/16"
  services_cidr = "10.30.0.0/20"
}

# Nodes run as their own service account with only what nodes need, not as the
# project's default Compute Engine account.
resource "google_service_account" "nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes (lab)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

module "cluster" {
  source = "../gke-cluster"

  name                = "lab"
  project_id          = var.project_id
  location            = var.zone
  network_id          = module.network.network_id
  subnet_id           = module.network.subnet_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  admin_cidr          = var.admin_cidr
}

# Cluster add-ons and system pods (DNS, metrics) live here, and Argo CD, on on-demand nodes.
module "system_pool" {
  source = "../node-pool"

  name            = "system"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "e2-standard-2"
  min_nodes       = 1
  max_nodes       = 2
  spot            = false
  service_account = google_service_account.nodes.email
  labels          = { pool = "system" }
}

# Tenant workloads, the chat page among them. Scale-to-zero keeps the lab cheap; the
# cluster autoscaler adds nodes only when pods are waiting for room. On-demand, not
# Spot: on 2026-10-16 Google took the Spot machine back and had no Spot e2-standard-2
# left in the zone (ZONE_RESOURCE_POOL_EXHAUSTED), and the page stayed down. With the
# cluster up only during a session, on-demand costs a few cents more an hour.
module "apps_pool" {
  source = "../node-pool"

  name            = "apps"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "e2-standard-2"
  min_nodes       = 0
  max_nodes       = 3
  spot            = false
  service_account = google_service_account.nodes.email
  labels          = { pool = "apps" }

  # Without this taint, system pods that could not fit elsewhere landed here during
  # cluster creation and kept the pool off zero for over an hour (seen 2026-10-14).
  # Tenant pods must tolerate it: key workload, value apps, effect NoSchedule.
  taints = [{ key = "workload", value = "apps", effect = "NO_SCHEDULE" }]
}

# One NVIDIA L4 (24 GB) per node, for model serving, in two pools that are the same
# machine: gpu on Spot, and gpu-ondemand for when Google has no Spot L4 free in the
# zone (on 2026-10-16 it had none, ZONE_RESOURCE_POOL_EXHAUSTED, and the model never
# started). The compute class gpu-l4 (apps/chat/values.yaml) tries gpu first, then
# gpu-ondemand; a pool takes part through the class's label and taint. Both scale
# from zero, and each project's GPU quota allows one GPU at a time (Spot or not), so
# each max is 1 and only one of them ever has a node.
module "gpu_pool" {
  source = "../node-pool"

  name            = "gpu"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "g2-standard-4"
  min_nodes       = 0
  max_nodes       = 1
  spot            = true
  service_account = google_service_account.nodes.email
  labels          = { pool = "gpu", "cloud.google.com/compute-class" = "gpu-l4" }
  taints          = [{ key = "cloud.google.com/compute-class", value = "gpu-l4", effect = "NO_SCHEDULE" }]
  disk_size_gb    = 50
  gpu             = { type = "nvidia-l4", count = 1 }
}

module "gpu_ondemand_pool" {
  source = "../node-pool"

  name            = "gpu-ondemand"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "g2-standard-4"
  min_nodes       = 0
  max_nodes       = 1
  spot            = false
  service_account = google_service_account.nodes.email
  labels          = { pool = "gpu-ondemand", "cloud.google.com/compute-class" = "gpu-l4" }
  taints          = [{ key = "cloud.google.com/compute-class", value = "gpu-l4", effect = "NO_SCHEDULE" }]
  disk_size_gb    = 50
  gpu             = { type = "nvidia-l4", count = 1 }
}
