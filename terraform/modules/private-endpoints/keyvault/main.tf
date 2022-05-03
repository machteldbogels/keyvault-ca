resource "azurerm_subnet" "kv_subnet" {
  name                 = "snet-kv"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [cidrsubnet(var.cidr_prefix, 8, 7)]

  enforce_private_link_endpoint_network_policies = true
}

resource "azurerm_network_security_group" "kv_nsg" {
  name                = "nsg-kv-${var.resource_uid}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_subnet_network_security_group_association" "kv_subnet_assoc" {
  subnet_id                 = azurerm_subnet.kv_subnet.id
  network_security_group_id = azurerm_network_security_group.kv_nsg.id
}

resource "azurerm_private_dns_zone" "kv_dns_zone" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv_dns_link" {
  name                  = "kv-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.kv_dns_zone.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_dns_a_record" "kv_dns_a_record" {
  name                = "kv-private-dns-a-record"
  zone_name           = azurerm_private_dns_zone.kv_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [cidrhost(azurerm_subnet.kv_subnet.address_prefixes[0], 1)]
}

resource "azurerm_private_endpoint" "kv_private_endpoint" {
  name                = "pe-kv-${var.resource_uid}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.kv_subnet.id

  private_service_connection {
    name                           = "kv_connection"
    private_connection_resource_id = var.keyvault_id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "pdnsz-kv-${var.resource_uid}"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv_dns_zone.id]
  }

  depends_on = [var.run_api_facade_null_resource_id, var.keyvault_id]
}