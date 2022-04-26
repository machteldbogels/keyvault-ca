resource "azurerm_iothub" "iothub" {
  name                          = "iot-${var.resource_prefix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  public_network_access_enabled = false

  sku {
    name     = "S1"
    capacity = "1"
  }

  fallback_route {
    source         = "DeviceMessages"
    endpoint_names = ["events"]
    enabled        = true
  }
}

resource "azurerm_iothub_shared_access_policy" "iot_hub_dps_shared_access_policy" {
  name                = "iot-hub-dps-access"
  resource_group_name = var.resource_group_name
  iothub_name         = azurerm_iothub.iothub.name

  registry_read   = true
  registry_write  = true
  service_connect = true
  device_connect  = true

  # Explicit dependency statement needed to prevent shared_access_policy
  # creation to start prematurely.
  depends_on = [azurerm_iothub.iothub]
}

resource "azurerm_iothub_dps" "iot_dps" {
  name                          = "provs-${var.resource_prefix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  public_network_access_enabled = true

  sku {
    name     = "S1"
    capacity = "1"
  }

  linked_hub {
    connection_string       = azurerm_iothub_shared_access_policy.iot_hub_dps_shared_access_policy.primary_connection_string
    location                = var.location
    apply_allocation_policy = true
  }

  depends_on = [azurerm_iothub_shared_access_policy.iot_hub_dps_shared_access_policy]
}

# Currently using local exec instead of azurerm_iothub_dps_certificate due to missing option to verify CA during upload in Terraform, missing ability to create enrollment groups and to retrieve cert from Key Vault instead of manual download
resource "null_resource" "dps_rootca_enroll" {
  triggers = {
    cer = "${var.issuing_ca}.cer"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = "${path.root}/../KeyVaultCA.Web/TrustedCAs"
    when        = create
    command     = <<EOF
      set -Eeuo pipefail

      az config set extension.use_dynamic_install=yes_without_prompt

      CERT_NAME=$(az iot dps certificate list -g ${var.resource_group_name} --dps-name ${azurerm_iothub_dps.iot_dps.name} --query "value[?name=='${var.issuing_ca}'].name" -o tsv)

      if [ -z "$CERT_NAME" ]
      then
        az keyvault certificate download --vault-name ${var.keyvault_name} -n ${var.issuing_ca} -f ${self.triggers.cer} -e PEM
        az iot dps certificate create -g ${var.resource_group_name} -n ${var.issuing_ca} --dps-name ${azurerm_iothub_dps.iot_dps.name} -p ${self.triggers.cer} -v true
      else
        echo "Cert ${var.issuing_ca} already exists."
      fi

      az iot dps enrollment-group create -g ${var.resource_group_name} --dps-name ${azurerm_iothub_dps.iot_dps.name} --eid ${var.resource_prefix}-enrollmentgroup --ee true --cn ${var.issuing_ca}
    EOF
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = "${path.root}/../KeyVaultCA.Web/TrustedCAs"
    when        = destroy
    command     = "rm -f ${self.triggers.cer}"
  }

  provisioner "local-exec" {
    command = "az iot dps update  --name ${azurerm_iothub_dps.iot_dps.name} --resource-group ${var.resource_group_name} --set properties.publicNetworkAccess=Disabled"
  }

  depends_on = [azurerm_iothub_dps.iot_dps, var.run_api_facade_null_resource_id]
}

resource "azurerm_subnet" "iot_subnet" {
  name                 = "iot-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.3.0/24"]

  enforce_private_link_endpoint_network_policies = true
}

# IOT HUB
resource "azurerm_private_dns_zone" "iothub_dns_zone" {
  name                = "privatelink.azure-devices.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "iothub_dns_link" {
  name                  = "iothub_dns_link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.iothub_dns_zone.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_dns_a_record" "iothub_dns_a_record" {
  name                = "iothub-private-dns-a-record"
  zone_name           = azurerm_private_dns_zone.iothub_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = ["10.0.3.2"]
}

resource "azurerm_private_endpoint" "iothub_private_endpoint" {
  name                = "priv-endpoint-iothub-${var.resource_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.iot_subnet.id

  private_service_connection {
    name                           = "iothub_connection"
    private_connection_resource_id = azurerm_iothub.iothub.id
    is_manual_connection           = false
    subresource_names              = ["iotHub"]
  }

  private_dns_zone_group {
    name                 = "iothub-dns-zone-group-${var.resource_prefix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.iothub_dns_zone.id]
  }

  depends_on = [azurerm_iothub_shared_access_policy.iot_hub_dps_shared_access_policy]
}

# DEVICE PROVISIONING SERVICE
resource "azurerm_private_dns_zone" "dps_dns_zone" {
  name                = "privatelink.azure-devices-provisioning.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dps_dns_link" {
  name                  = "dps_dns_link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.dps_dns_zone.name
  virtual_network_id    = var.vnet_id
}

resource "azurerm_private_dns_a_record" "dps_dns_a_record" {
  name                = "dps-private-dns-a-record"
  zone_name           = azurerm_private_dns_zone.dps_dns_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = ["10.0.3.1"]
}

resource "azurerm_private_endpoint" "dps_private_endpoint" {
  name                = "priv-endpoint-dps-${var.resource_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.iot_subnet.id

  private_service_connection {
    name                           = "dps_connection"
    private_connection_resource_id = azurerm_iothub_dps.iot_dps.id
    is_manual_connection           = false
    subresource_names              = ["iotDps"]
  }

  private_dns_zone_group {
    name                 = "dps-dns-zone-group${var.resource_prefix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.dps_dns_zone.id]
  }

  depends_on = [azurerm_iothub_dps.iot_dps, null_resource.dps_rootca_enroll]
}

# BASTION HOST
resource "azurerm_subnet" "bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.2.0/26"]
}

resource "azurerm_public_ip" "public_ip" {
  name                = "bastion-ip-${var.resource_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bastion" {
  name                = "bastion-host-${var.resource_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                 = "AzureBastionSubnet-Configuration"
    subnet_id            = azurerm_subnet.bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.public_ip.id
  }
}