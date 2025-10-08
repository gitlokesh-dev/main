

variable "location" {
   type = string
}

# Networking
variable "resource_group_name" {
  type = string
}
variable "pl_resource_group_name" {
  type = string
}
variable "vnet_name" {
   type = string

}
variable "subnet_name" {
  type = string

}
variable "nsg_name" {
   
    type = string
}


# VM settings
variable "vm_name" {}
variable "vm_size" {
  default = "Standard_D2s_v3"
}
variable "admin_username" {}
variable "admin_password" {}
