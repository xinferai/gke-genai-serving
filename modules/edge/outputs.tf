# The two records to add to the liveinference.com zone in Route 53.
output "dns_records" {
  value = {
    a = {
      name  = var.hostname
      type  = "A"
      value = google_compute_global_address.chat.address
    }
    certificate_check = {
      name  = google_certificate_manager_dns_authorization.chat.dns_resource_record[0].name
      type  = google_certificate_manager_dns_authorization.chat.dns_resource_record[0].type
      value = google_certificate_manager_dns_authorization.chat.dns_resource_record[0].data
    }
  }
}

# Names the Gateway manifest refers to.
output "address_name" {
  value = google_compute_global_address.chat.name
}

output "certificate_map" {
  value = google_certificate_manager_certificate_map.chat.name
}

output "security_policy" {
  value = google_compute_security_policy.chat.name
}

# The disk the chat app's PersistentVolume is (apps/chat/values.yaml, volumeHandle).
output "data_disk" {
  value = google_compute_disk.chat_data.id
}
