##################################################################################
# LOCALS
##################################################################################

locals {
  resource_group_name    = "${var.naming_prefix}-${random_integer.sa_num.result}"
  storage_account_name   = "${lower(var.naming_prefix)}${random_integer.sa_num.result}"
  service_principal_name = "${var.naming_prefix}-${random_integer.sa_num.result}"
}

##################################################################################
# RESOURCES
##################################################################################

## AZURE AD SP ##

data "azurerm_subscription" "current" {}

data "azuread_client_config" "current" {}



resource "random_integer" "sa_num" {
  min = 10000
  max = 99999
}

resource "azurerm_resource_group" "setup" {
  name     = local.resource_group_name
  location = var.location
}



## GitHub secrets

resource "github_actions_secret" "actions_secret" {
  for_each = {
    STORAGE_ACCOUNT     = azurerm_storage_account.sa.name
    RESOURCE_GROUP      = azurerm_storage_account.sa.resource_group_name
    CONTAINER_NAME      = azurerm_storage_container.ct.name
    ARM_CLIENT_ID       = azuread_service_principal.gh_actions.application_id
    ARM_CLIENT_SECRET   = azuread_service_principal_password.gh_actions.value
    ARM_SUBSCRIPTION_ID = data.azurerm_subscription.current.subscription_id
    ARM_TENANT_ID       = data.azuread_client_config.current.tenant_id
  }

  repository      = var.github_repository
  secret_name     = each.key
  plaintext_value = each.value
}
