resource "azurerm_container_registry" "acr" {
  name                          = "${var.resource_prefix}acr"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium" # Needs to be premium in order to disable public network access
  admin_enabled                 = true
  public_network_access_enabled = true
}

resource "azurerm_subnet" "acr_subnet" {
  name                 = "${var.resource_prefix}-acr-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.4.0/24"]

  enforce_private_link_endpoint_network_policies = true
}

resource "azurerm_private_dns_zone" "acr_dns_zone" {
  name                = "privatelink.azurecr.io"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_dns_link" {
  name                  = "acr_dns_link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.acr_dns_zone.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_dns_a_record" "acr_dns_a_record" {
  name                = "acr-private-dns-a-record"
  zone_name           = azurerm_private_dns_zone.acr_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = ["10.0.4.1"]
}

resource "azurerm_private_endpoint" "acr_private_endpoint" {
  name                = "${var.resource_prefix}-acr-private-endpoint"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.acr_subnet.id

  private_service_connection {
    name                           = "acr_connection"
    private_connection_resource_id = azurerm_container_registry.acr.id
    is_manual_connection           = false
    subresource_names              = ["registry"]
  }

  private_dns_zone_group {
    name                           = "${var.resource_prefix}-acr-dns-zone-group"
    private_dns_zone_ids           = [azurerm_private_dns_zone.acr_dns_zone.id]
  }

  depends_on = [
    azurerm_container_registry.acr, null_resource.push-docker
  ]
}

resource "null_resource" "push-docker" {
  provisioner "local-exec" {
    command = "az acr build --image sample/estserver:v2 --registry ${azurerm_container_registry.acr.name} https://github.com/machteldbogels/keyvault-ca.git --file ./././KeyVaultCA.Web/Dockerfile"
  }

  provisioner "local-exec" {
    command = "az acr import --name ${azurerm_container_registry.acr.name} --source mcr.microsoft.com/azureiotedge-agent:1.2 --image azureiotedge-agent:1.2"
  }

  provisioner "local-exec" {
    command = "az acr update --name ${azurerm_container_registry.acr.name} --public-network-enabled false"
  }

}