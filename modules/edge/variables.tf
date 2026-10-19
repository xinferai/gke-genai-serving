variable "name" {
  description = "Name of the IP, certificate, certificate map and Cloud Armor policy. Names are unique per project, so both environments use the default."
  type        = string
  default     = "chat-lab"
}

variable "hostname" {
  description = "The public name of the chat app. Its DNS lives in Route 53, outside the project."
  type        = string
}

variable "allowed_cidrs" {
  description = "Callers Cloud Armor lets through. Everyone else gets a 403 at Google's edge."
  type        = list(string)
}

variable "zone" {
  description = "Zone of the chat data disk: the cluster's, since a zonal disk attaches only to nodes in its own zone."
  type        = string
}
