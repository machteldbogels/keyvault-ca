output "app_hostname" {
  value = azurerm_linux_web_app.appservice.default_hostname
}

output "est_user" {
  value     = var.est_user
  sensitive = true
}

output "est_password" {
  value     = var.est_password
  sensitive = true
}

output "app_princ_id" {
  value     = azurerm_linux_web_app.appservice.identity.0.principal_id
}