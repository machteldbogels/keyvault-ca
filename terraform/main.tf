terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.2.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

resource "random_id" "prefix" {
  byte_length = 4
  prefix      = "s"
}

locals {
  resource_prefix  = var.resource_prefix == "" ? lower(random_id.prefix.hex) : var.resource_prefix
  issuing_ca       = "${local.resource_prefix}-ca"
  edge_device_name = "${local.resource_prefix}-edge-device"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.resource_prefix}-keyvault-ca"
  location = var.location
}

module "keyvault" {
  source              = "./modules/keyvault"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  resource_prefix     = local.resource_prefix
  app_princ_id        = module.appservice.app_princ_id
  vnet_name           = module.iot_edge.vnet_name
  vnet_id             = module.iot_edge.vnet_id
  issuing_ca          = local.issuing_ca
}

module "acr" {
  source              = "./modules/acr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  resource_prefix     = local.resource_prefix
  vnet_name           = module.iot_edge.vnet_name
  vnet_id             = module.iot_edge.vnet_id
  app_princ_id        = module.appservice.app_princ_id
}

module "appservice" {
  source              = "./modules/appservice"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  resource_prefix     = local.resource_prefix
  issuing_ca          = local.issuing_ca
  keyvault_url        = module.keyvault.keyvault_url 
  keyvault_name       = module.keyvault.keyvault_name
  acr_login_server    = module.acr.acr_login_server
  vnet_name           = module.iot_edge.vnet_name
  vnet_id             = module.iot_edge.vnet_id
  iotedge_subnet_id   = module.iot_edge.iotedge_subnet_id
}

module "iot_hub" {
  source              = "./modules/iot-hub"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  resource_prefix     = local.resource_prefix
  edge_device_name    = local.edge_device_name
  issuing_ca          = local.issuing_ca
  keyvault_name       = module.keyvault.keyvault_name
  vnet_name           = module.iot_edge.vnet_name
  vnet_id             = module.iot_edge.vnet_id
}

module "iot_edge" {
  source              = "./modules/iot-edge"
  resource_prefix     = local.resource_prefix
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  vm_sku              = var.edge_vm_sku
  dps_scope_id        = module.iot_hub.iot_dps_scope_id
  edge_device_name    = local.edge_device_name
  app_hostname        = module.appservice.app_hostname
  est_username        = module.appservice.est_username
  est_password        = module.appservice.est_password
  iot_dps_name        = module.iot_hub.iot_dps_name
  acr_admin_username  = module.acr.acr_admin_username
  acr_admin_password  = module.acr.acr_admin_password
  acr_name            = module.acr.acr_name
}

resource "null_resource" "disable_public_network" {
  provisioner "local-exec" {
    command = "az acr update --name ${module.acr.acr_name} --public-network-enabled false"
  }

  provisioner "local-exec" {
    command = "az iot dps update  --name ${module.iot_hub.iot_dps_name} --resource-group ${azurerm_resource_group.rg.name} --set properties.publicNetworkAccess=Disabled"
  }

  provisioner "local-exec" {
    command = "az keyvault update --name ${module.keyvault.keyvault_name} --public-network-access Disabled"
  }

  depends_on = [module.acr, module.iot_hub]

  triggers = {
    timestamp = timestamp()
  }
}
