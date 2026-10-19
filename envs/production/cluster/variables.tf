variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  description = "A zonal cluster: GKE waives the management fee for one per billing account."
  type        = string
}

variable "admin_cidr" {
  description = "The only address range allowed to reach the cluster's control plane."
  type        = string
}
