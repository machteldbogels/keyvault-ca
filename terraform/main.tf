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
  prefix      = "L"
}

resource "random_string" "vm_user_name" {
  length  = 10
  special = false
}

resource "random_string" "vm_password" {
  length  = 10
  number  = true
  special = true
}

locals {
  resource_prefix  = var.resource_prefix == "" ? lower(random_id.prefix.hex) : var.resource_prefix
  issuing_ca       = "${local.resource_prefix}-ca"
  edge_device_name = "${local.resource_prefix}-edge-device"
  certs_path       = "../Certs/${local.resource_prefix}"
  vm_user_name     = var.vm_user_name != "" ? var.vm_user_name : random_string.vm_user_name.result
  vm_password      = var.vm_password != "" ? var.vm_password : random_string.vm_password.result
}

resource "azurerm_resource_group" "rg" {
  name     = "${local.resource_prefix}-keyvault-ca-rg"
  location = var.location
}

module "keyvault" {
  source              = "./modules/keyvault"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  resource_prefix     = local.resource_prefix
  vnet_name           = module.iot_edge.vnet_name
  vnet_id             = module.iot_edge.vnet_id
}

module "acr" {
  source               = "./modules/acr"
  resource_group_name  = azurerm_resource_group.rg.name
  location             = var.location
  resource_prefix      = local.resource_prefix
  vnet_name            = module.iot_edge.vnet_name
  vnet_id              = module.iot_edge.vnet_id
  app_princ_id         = module.appservice.app_princ_id 
}

module "appservice" {
  source              = "./modules/appservice"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  resource_prefix     = local.resource_prefix
  issuing_ca          = local.issuing_ca
  keyvault_id         = module.keyvault.keyvault_id
  keyvault_url        = module.keyvault.keyvault_url
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
  vm_user_name        = local.vm_user_name
  vm_password         = local.vm_password
  vm_sku              = var.edge_vm_sku
  dps_scope_id        = module.iot_hub.iot_dps_scope_id
  edge_vm_name        = local.edge_device_name
  app_hostname        = module.appservice.app_hostname
  est_user            = module.appservice.est_user
  est_password        = module.appservice.est_password
  iot_dps_name        = module.iot_hub.iot_dps_name
  acr_admin_username  = module.acr.acr_admin_username
  acr_admin_password  = module.acr.acr_admin_password
  acr_name            = module.acr.acr_name
}

resource "null_resource" "run-api-facade" {
  provisioner "local-exec" {
    working_dir = "../KeyvaultCA"
    command     = "dotnet run --Csr:IsRootCA true --Csr:Subject ${"C=US, ST=WA, L=Redmond, O=Contoso, OU=Contoso HR, CN=Contoso Inc"} --Keyvault:IssuingCA ${local.issuing_ca} --Keyvault:KeyVaultUrl ${module.keyvault.keyvault_url}"
  }

  provisioner "local-exec" {
    working_dir = "../KeyVaultCA"
    command     = "openssl genrsa -out ${local.certs_path}.key 2048"
  }

  provisioner "local-exec" {
    working_dir = "../KeyVaultCA"
    command     = "openssl req -new -key ${local.certs_path}.key -subj \"/C=US/ST=WA/L=Redmond/O=Contoso/CN=Contoso Inc\" -out ${local.certs_path}.csr"
    interpreter = ["PowerShell", "-Command"]
  }

  provisioner "local-exec" {
    working_dir = "../KeyVaultCA"
    command     = "openssl req -in ${local.certs_path}.csr -out ${local.certs_path}.csr.der -outform DER"
  }

  provisioner "local-exec" {
    working_dir = "../KeyVaultCA"
    command     = "dotnet run --Csr:IsRootCA false --Csr:PathToCsr ${local.certs_path}.csr.der --Csr:OutputFileName ${local.certs_path}-cert --Keyvault:IssuingCA ${local.issuing_ca} --Keyvault:KeyVaultUrl ${module.keyvault.keyvault_url}"
  }
}


resource "null_resource" "disable_public_network" {
  provisioner "local-exec" {
    command = "az acr update --name ${module.acr.acr_name} --public-network-enabled false"
  }
  
  provisioner "local-exec" {
    command = "az iot dps update  --name ${module.iot_hub.iot_dps_name} --resource-group ${azurerm_resource_group.rg.name} --set properties.publicNetworkAccess=Disabled"
  }

  depends_on = [
    module.acr,module.iot_hub
  ]

  triggers = {
    timestamp = timestamp()
  }
}