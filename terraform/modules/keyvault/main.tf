data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "keyvault-ca" {
  name                        = "${var.resource_prefix}-keyvault-ca"
  location                    = var.location
  resource_group_name         = var.resource_group_name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled    = false
  soft_delete_retention_days  = 7
  sku_name                    = "standard"

  network_acls {
    # The Default Action to use when no rules match from ip_rules / 
    # virtual_network_subnet_ids. Possible values are Allow and Deny
    default_action = "Deny"

    # Allows all azure services to acces your keyvault. Can be set to 'None'
    bypass         = "AzureServices"

    #virtual_network_subnet_ids = [var.vnet_id] # add subnet id of appservice subnet -> can lead to cycle!!
  }
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