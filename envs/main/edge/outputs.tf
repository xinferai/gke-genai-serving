# The two records to add to the liveinference.com zone in Route 53.
output "dns_records" {
  value = module.edge.dns_records
}

# Names the Gateway manifest refers to.
output "address_name" {
  value = module.edge.address_name
}

output "certificate_map" {
  value = module.edge.certificate_map
}

output "security_policy" {
  value = module.edge.security_policy
}

# The disk the chat app's PersistentVolume is (apps/chat/values.yaml, volumeHandle).
output "data_disk" {
  value = module.edge.data_disk
}
