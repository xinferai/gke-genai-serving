variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "hostname" {
  description = "The public name of the chat app. Its DNS lives in Route 53, outside this project."
  type        = string
}

variable "allowed_cidrs" {
  description = "Callers Cloud Armor lets through. Everyone else gets a 403 at Google's edge."
  type        = list(string)
}

variable "zone" {
  description = "The cluster's zone (envs/<env>/cluster), where the chat data disk is kept."
  type        = string
}
