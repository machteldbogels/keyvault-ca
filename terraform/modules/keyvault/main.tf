data "azurerm_client_config" "current" {}

locals {
  certs_path = "${path.root}/../Certs/${var.resource_prefix}"
}

resource "azurerm_key_vault" "keyvault-ca" {
  name                        = "kv-${var.resource_prefix}"
  location                    = var.location
  resource_group_name         = var.resource_group_name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled    = false
  soft_delete_retention_days  = 7
  sku_name                    = "standard"
}

resource "azurerm_subnet" "kv_subnet" {
  name                 = "${var.resource_prefix}-kv-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.7.0/24"]

  enforce_private_link_endpoint_network_policies = true
}

resource "azurerm_private_dns_zone" "kv_dns_zone" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv_dns_link" {
  name                  = "kv_dns_link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.kv_dns_zone.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_dns_a_record" "kv_dns_a_record" {
  name                = "kv-private-dns-a-record"
  zone_name           = azurerm_private_dns_zone.kv_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = ["10.0.7.1"]
}

resource "azurerm_private_endpoint" "kv_private_endpoint" {
  name                = "${var.resource_prefix}-kv-private-endpoint"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.kv_subnet.id

  private_service_connection {
    name                           = "kv_connection"
    private_connection_resource_id = azurerm_key_vault.keyvault-ca.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "${var.resource_prefix}-kv-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv_dns_zone.id]
  }

  depends_on = [azurerm_key_vault.keyvault-ca]
}

resource "azurerm_key_vault_access_policy" "app_accesspolicy" {
  key_vault_id = azurerm_key_vault.keyvault-ca.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.app_princ_id

  key_permissions = ["Sign"]

  certificate_permissions = ["Get", "List", "Update", "Create"]
}

resource "azurerm_key_vault_access_policy" "user_accesspolicy" {
  key_vault_id = azurerm_key_vault.keyvault-ca.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = ["Sign"]

  certificate_permissions = ["Get", "List", "Update", "Create", "Import", "Delete", "Recover", "Backup", "Restore", "ManageIssuers", "GetIssuers", "ListIssuers", "SetIssuers", "DeleteIssuers"]
}

resource "null_resource" "run-api-facade" {
  triggers = {
    key     = "${local.certs_path}.key"
    csr     = "${local.certs_path}.csr"
    csr_der = "${local.certs_path}.csr.der"
    cert    = "${local.certs_path}-cert"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = "${path.root}/../KeyvaultCA"
    when        = create
    command     = <<EOF
      set -Eeuo pipefail

      dotnet run --Csr:IsRootCA true --Csr:Subject "C=US, ST=WA, L=Redmond, O=Contoso, OU=Contoso HR, CN=Contoso Inc" --Keyvault:IssuingCA ${var.issuing_ca} --Keyvault:KeyVaultUrl ${azurerm_key_vault.keyvault-ca.vault_uri}
      openssl genrsa -out ${self.triggers.key} 2048
      openssl req -new -key ${self.triggers.key} -subj "/C=US/ST=WA/L=Redmond/O=Contoso/CN=Contoso Inc" -out ${self.triggers.csr}
      openssl req -in ${self.triggers.csr} -out ${self.triggers.csr_der} -outform DER
      dotnet run --Csr:IsRootCA false --Csr:PathToCsr ${self.triggers.csr_der} --Csr:OutputFileName ${self.triggers.cert} --Keyvault:IssuingCA ${var.issuing_ca} --Keyvault:KeyVaultUrl ${azurerm_key_vault.keyvault-ca.vault_uri}
    EOF
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = "${path.root}/../KeyvaultCA"
    when        = destroy
    command     = "rm -f ${self.triggers.key} ${self.triggers.csr} ${self.triggers.csr_der} ${self.triggers.cert}"
  }
}