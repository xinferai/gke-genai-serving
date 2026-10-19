# One environment's public entrance. This file is the same in envs/main and envs/production (./check
# compares them): the environments differ only in terraform.tfvars and in where versions.tf keeps
# the state. Production also has moved.tf.
module "edge" {
  source = "../../../modules/edge"

  hostname      = var.hostname
  allowed_cidrs = var.allowed_cidrs
  zone          = var.zone
}
