
#############################################################################
# VARIABLES
#############################################################################

variable "location" {
  type    = string
  default = "eastus"
}

variable "naming_prefix" {
  type    = string
  default = "shell"
}

variable "github_repository" {
  type    = string
  default = "shell-github-actions"
}

/*# Common
variable "resource_group_name" {}
variable "pl_resource_group_name" {}
variable "location" {}

# Network
variable "vnet_name" {}
variable "nsg_name" {}
variable "subnet_name" {}
# VM Settings
variable "vm_name" {}
variable "vm_size" {}
variable "admin_username" {}
variable "admin_password" {}

# Domain Join
variable "domain_name" {}
variable "domain_user" {}
variable "domain_password" {}
variable "ou_path" {}*/