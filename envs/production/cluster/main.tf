# One environment's cluster. This file is the same in envs/main and envs/production (./check compares
# them): the environments differ only in terraform.tfvars and in where versions.tf keeps the state.
module "platform" {
  source = "../../../modules/platform"

  project_id = var.project_id
  region     = var.region
  zone       = var.zone
  admin_cidr = var.admin_cidr
}
