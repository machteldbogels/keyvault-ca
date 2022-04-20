variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_prefix" {
  type = string
}

variable "keyvault_url" {
  type = string
}

variable "authmode" {
  type    = string
  default = "Basic"
}

variable "est_user" {
  type    = string
  default = "foo"
}

variable "est_password" {
  type    = string
  default = "bar"
}

variable "issuing_ca" {
  type = string
}

variable "cert_validity_in_days" {
  type    = string
  default = "365"
}

variable "acr_login_server" {
  type = string
}

variable "keyvault_id" {
  type = string
}

variable "vnet_name" {
  type = string
}

variable "vnet_id" {
  type = string
}

variable "iotedge_subnet_id" {
  type = string
}