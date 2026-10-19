# The long-lived half of the chat app's public entrance, for one environment, and the chat app's data
# disk. The load balancer itself is created by the Gateway in the cluster (apps/chat/edge/) and goes
# away with the cluster; these stay, so the IP address, the certificate, the DNS records and the
# accounts and chats survive ./tf <env> cluster destroy.

resource "google_project_service" "certificatemanager" {
  service            = "certificatemanager.googleapis.com"
  disable_on_destroy = false
}

# The load balancer's fixed public IP. The DNS A record points here.
resource "google_compute_global_address" "chat" {
  name = var.name
}

# Google proves control of the hostname through a CNAME record under it, then issues the
# certificate and renews it on its own. The AWS equivalent is ACM with DNS validation.
resource "google_certificate_manager_dns_authorization" "chat" {
  name   = var.name
  domain = var.hostname

  depends_on = [google_project_service.certificatemanager]
}

resource "google_certificate_manager_certificate" "chat" {
  name = var.name

  managed {
    domains            = [var.hostname]
    dns_authorizations = [google_certificate_manager_dns_authorization.chat.id]
  }
}

# The Gateway picks its certificate through this map, by name.
resource "google_certificate_manager_certificate_map" "chat" {
  name = var.name

  depends_on = [google_project_service.certificatemanager]
}

resource "google_certificate_manager_certificate_map_entry" "chat" {
  name         = var.name
  map          = google_certificate_manager_certificate_map.chat.name
  hostname     = var.hostname
  certificates = [google_certificate_manager_certificate.chat.id]
}

# Cloud Armor, checked at Google's edge before any request reaches the cluster: allowed_cidrs
# get through, everyone else gets a 403. The AWS equivalent is a WAF web ACL with an IP set.
resource "google_compute_security_policy" "chat" {
  name = var.name

  rule {
    description = "Allowed callers"
    action      = "allow"
    priority    = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.allowed_cidrs
      }
    }
  }

  rule {
    description = "Everyone else"
    action      = "deny(403)"
    priority    = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# The chat app's data: Open WebUI's database (accounts, passwords, chats, API keys) and its uploads.
# Kept here so that it outlives the cluster: the cluster's PersistentVolume chat-data
# (apps/chat/values.yaml) is this disk, by name, and deleting that volume at teardown leaves the disk
# alone (Retain). The AWS equivalent is an EBS volume made outside the EKS cluster and attached by its
# ID. A zonal disk attaches only to nodes in its own zone: the cluster's (./check compares the two).
# prevent_destroy: a plan that would delete or replace it fails instead. To delete the data for good,
# take it out first.
resource "google_compute_disk" "chat_data" {
  name = "chat-data"
  zone = var.zone
  type = "pd-balanced"
  # GB. The smallest pd-balanced disk Google makes; the data itself is far smaller.
  size = 10

  lifecycle {
    prevent_destroy = true
  }
}
