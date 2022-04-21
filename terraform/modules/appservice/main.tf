data "azurerm_client_config" "current" {}

resource "azurerm_application_insights" "appinsights" {
  name                = "${var.resource_prefix}-appinsights"
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
}


resource "azurerm_service_plan" "appserviceplan" {
  name                = "${var.resource_prefix}-appserviceplan"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = "S1"
}

resource "azurerm_linux_web_app" "appservice" {
  name                       = "${var.resource_prefix}-appservice"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  service_plan_id            = azurerm_service_plan.appserviceplan.id
  client_certificate_enabled = var.authmode == "Basic" ? false : true
  client_certificate_mode    = var.authmode == "Basic" ? "Optional" : "Required"

  site_config {
    application_stack {
      docker_image     = "${var.acr_login_server}/sample/estserver"
      docker_image_tag = "v2"
    }

    # ip_restriction = [ {
    #   action = "Allow"
    #   virtual_network_subnet_id = var.iotedge_subnet_id
    # } ]

    container_registry_use_managed_identity = true
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE          = false
    "Keyvault__KeyVaultUrl"                      = "https://${var.keyvault_name}.privatelink.vaultcore.azure.net/"
    "EstAuthentication__Auth"                    = var.authmode
    "EstAuthentication__EstUsername"             = var.est_user
    "EstAuthentication__EstPassword"             = var.est_password
    "KeyVault__IssuingCA"                        = var.issuing_ca
    "KeyVault__CertValidityInDays"               = var.cert_validity_in_days
    "APPINSIGHTS_INSTRUMENTATIONKEY"             = azurerm_application_insights.appinsights.instrumentation_key
    "ApplicationInsights__ConnectionString"      = azurerm_application_insights.appinsights.connection_string
    "ApplicationInsightsAgent_EXTENSION_VERSION" = "~2"
    "WEBSITE_PULL_IMAGE_OVER_VNET"               = true
  }
}

resource "azurerm_key_vault_access_policy" "app_accesspolicy" {
  key_vault_id = var.keyvault_id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_web_app.appservice.identity.0.principal_id

  key_permissions = ["Sign"]

  certificate_permissions = ["Get", "List", "Update", "Create"]
}

resource "azurerm_key_vault_access_policy" "user_accesspolicy" {
  key_vault_id = var.keyvault_id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = ["Sign"]

  certificate_permissions = ["Get", "List", "Update", "Create", "Import", "Delete", "Recover", "Backup", "Restore", "ManageIssuers", "GetIssuers", "ListIssuers", "SetIssuers", "DeleteIssuers"]
}

resource "azurerm_subnet" "app_subnet" {
  name                 = "${var.resource_prefix}-app-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.5.0/24"]

  enforce_private_link_endpoint_network_policies = true
}

resource "azurerm_subnet" "app_vnet_integration_subnet" {
  name                 = "${var.resource_prefix}-app-vnet-integrationsubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.6.0/24"]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "app_dns_zone" {
  name                = "privatelink.azurewebsites.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "app_dns_link" {
  name                  = "app_dns_link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.app_dns_zone.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_dns_a_record" "app_dns_a_record" {
  name                = "app-private-dns-a-record"
  zone_name           = azurerm_private_dns_zone.app_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = ["10.0.5.1"]
}

resource "azurerm_private_endpoint" "app_private_endpoint" {
  name                = "${var.resource_prefix}-app-private-endpoint"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.app_subnet.id

  private_service_connection {
    name                           = "app_connection"
    private_connection_resource_id = azurerm_linux_web_app.appservice.id
    is_manual_connection           = false
    subresource_names              = ["sites"]
  }

  private_dns_zone_group {
    name                 = "${var.resource_prefix}-app-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.app_dns_zone.id]
  }

  depends_on = [azurerm_linux_web_app.appservice]
}

resource "azurerm_app_service_virtual_network_swift_connection" "app_vnet_connection" {
  app_service_id = azurerm_linux_web_app.appservice.id
  subnet_id      = azurerm_subnet.app_vnet_integration_subnet.id
}