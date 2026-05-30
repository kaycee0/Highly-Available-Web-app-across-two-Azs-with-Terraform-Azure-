variable "project_name" {
  description = "Prefix used for all resource names and tags"
  type        = string
  default = "Redbull-Racing"
}

variable "location" {
  description = "Azure region to deploy into"
  type        = string
  default     = "eastus"
}

variable "vnet_cidr" {
  description = "CIDR block for the Virtual Network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "zones" {
  description = "List of availability zones (e.g. [\"1\", \"2\"])"
  type        = list(string)
  default     = ["1", "2"]
}