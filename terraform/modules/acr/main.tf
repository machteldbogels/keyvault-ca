resource "azurerm_container_registry" "acr" {
  name                          = "cr${var.resource_prefix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium" # Needs to be premium in order to disable public network access
  admin_enabled                 = true
  public_network_access_enabled = true
}

resource "azurerm_role_assignment" "acr_app_service" {
  principal_id         = var.app_princ_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

resource "azurerm_subnet" "acr_subnet" {
  name                 = "acr-subnet"
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
  name                = "priv-endpoint-acr-${var.resource_prefix}"
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
    name                 = "dns-zone-group-acr-${var.resource_prefix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr_dns_zone.id]
  }

  depends_on = [azurerm_container_registry.acr, null_resource.push-docker]
}

resource "null_resource" "push-docker" {
  provisioner "local-exec" {
    command = "az acr build -r ${azurerm_container_registry.acr.name} -t estserver:latest ../ -f ../KeyVaultCA.Web/Dockerfile"
  }

  provisioner "local-exec" {
    command = "az acr import --name ${azurerm_container_registry.acr.name} --source mcr.microsoft.com/azureiotedge-agent:1.2 --image azureiotedge-agent:1.2"
  }

  depends_on = [azurerm_container_registry.acr, var.dps_rootca_enroll_null_resource_id]
}