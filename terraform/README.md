## Infrastructure as code

The Terraform scripts listed under the `terraform` directory can be used to deploy the infrastructure required for E2E testing to an Azure environment. This deployment includes an App Service for the EST server to run in using an image pulled from Azure Container Registry, an Azure Key Vault for storing the Root CA and an IoT Hub, Device Provisioning Service and a Linux VM simulating an IoT Edge device. The Terraform template uses `dotnet run` to execute the API Facade Console App, hence installing the [.NET Runtime 6](https://dotnet.microsoft.com/en-us/download/dotnet/6.0) is required. The infrastructure can be deployed by cd'ing into the `terraform` directory and then running `terraform init` followed by `terraform apply`. Terraform will use the [logged in Azure user credentials](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli) and subsequent subscription to deploy the resources to.

### VNet integration

The Azure resources deployed through Terraform include VNet integration and private endpoints where possible. The architecture of this setup is shown in the image below. 

![Overview](../assets/vnet-arch.jpg "VNet Architecture")

Each private endpoint is located inside 'their own' subnet to ensure the ability to create security rules for each resource individually, except for the endpoints for IoT Hub and DPS since (in this case) traffic towards DPS is also expected to go into IoT Hub.

### Disabling public network access
When reusing these Terraform scripts, please be informed that public network access for ACR, Device Provisioning Service and Key Vault is enabled while running the scripts. This is necessary to configure the resources properly (i.e. downloading the certificate from Key Vault and then uploading to DPS) from the (local) machine where the scripts are executed. Public network access is then disabled for each service using Azure CLI commands as the last step of the deployment.

### Deploying without VNet integration
If the user wants to deploy the infrastructure without using private endpoints, this can be done by removing the `terraform/private-endpoints` directory (together with all its subdirectories) and remove/comment out the corresponding module declarations in `terraform/main.tf`. Also, make sure that the global provisioning endpoint is used for DPS instead of the private one, by (un)commenting the global_endpoint section in `terraform/iot-edge/cloud-init.yaml` such that it looks like this:

```yaml
      global_endpoint= "https://global.azure-devices-provisioning.net"
      #global_endpoint= "https://${DPS_NAME}.azure-devices-provisioning.net"
```
And finally, set the `public_network_access_enabled` flag as part of the IoT Hub resource creation, inside `terraform/modules/iot-hub-dps/main.tf`, to `true` instead of `false`. If there is a need to SSH into the Virtual Machine, you could enable just-in-time access or open Port 22 as it is closed per default in this setup.

### Authenticating to the EST server using certificates
The authentication mode is currently set to be `x509`, which means using certificates for authenticating to the EST server.

If you want to use `Basic` authentication with username and password, then you would need to replace the default value of `auth_mode` within `terraform/variables.tf` from `"x509"` to `"Basic"` and ensure that the `[cert_issuance.est.auth]` section in `terraform/iot-edge/cloud-init.yaml` looks like this:

```yaml
      [cert_issuance.est.auth]
      username = "${EST_USERNAME}"
      password = "${EST_PASSWORD}"
      
      #identity_cert = "file:///etc/aziot/estauth.pem"
      #identity_pk = "file:///etc/aziot/estauth.key.pem"
```

### Set up and run CD pipeline
A CD Pipeline to deploy the infrastructure and run an end-to-end test using GitHub Actions can be found inside the `.github/workflows` directory. In order to run this pipeline successfully, you would first need to [create a Service Principal](https://docs.microsoft.com/en-us/azure/developer/terraform/authenticate-to-azure?tabs=bash#create-a-service-principal) using the Azure CLI with [Owner](https://docs.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#owner) rights (including the ability to assign roles in Azure RBAC). Make a note of the `appId`, `password`, and `tenant` values which are returned as a result of this creation.

After that, you'll need to fork the repository and add these values individually as [repository secrets](https://github.com/Azure/actions-workflow-samples/blob/master/assets/create-secrets-for-GitHub-workflows.md) using the following secret names:

```
      AZURE_CLIENT_ID = <Your appId>
      AZURE_CLIENT_SECRET = <Your password>
      AZURE_SUBSCRIPTION_ID = <Your subscription id>
      AZURE_TENANT_ID = <Your tenant>
```