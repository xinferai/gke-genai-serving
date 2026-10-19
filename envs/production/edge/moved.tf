# Production's entrance was built on 2026-10-14 by envs/edge, with its resources at the top level.
# These blocks tell Terraform they now live in module.edge, so nothing is destroyed or recreated: the
# first plan lists seven moves and 0 to add, 0 to change, 0 to destroy, and one apply records them.
# Only production has this file; main's entrance is built in the module from the start.

moved {
  from = google_project_service.certificatemanager
  to   = module.edge.google_project_service.certificatemanager
}

moved {
  from = google_compute_global_address.chat
  to   = module.edge.google_compute_global_address.chat
}

moved {
  from = google_certificate_manager_dns_authorization.chat
  to   = module.edge.google_certificate_manager_dns_authorization.chat
}

moved {
  from = google_certificate_manager_certificate.chat
  to   = module.edge.google_certificate_manager_certificate.chat
}

moved {
  from = google_certificate_manager_certificate_map.chat
  to   = module.edge.google_certificate_manager_certificate_map.chat
}

moved {
  from = google_certificate_manager_certificate_map_entry.chat
  to   = module.edge.google_certificate_manager_certificate_map_entry.chat
}

moved {
  from = google_compute_security_policy.chat
  to   = module.edge.google_compute_security_policy.chat
}
