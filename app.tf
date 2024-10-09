variable "file_share_size" {
  type = map(map(string))
  description = "Map of file share sizes for each environment."
}

locals {
  app_mysql_admin_login = "admin${random_id.mysql_admin_login_suffix.hex}"
  app_pgsql_admin_login = "admin${random_id.mysql_admin_login_suffix.hex}"

  # Empty string only allowed when list has only one item
  cpenvprefix = {
    sbox = []
    devt = ["chrt-",
    "app-"]
    test = ["chrt-",
      "app-",
    ""]
    stag = [""]
    prod = [""]
  }

  build_tableau = ["devt", "stag", "prod"]
  tableau_lock = ["stag", "prod"]

  call_storage_env = ["devt", "prod"]

  mysqlfs_subnet_cidr = {
    sbox = ["172.27.96.224/29"]
    devt = ["172.26.96.240/29",
    "172.26.96.248/29"]
    test = ["172.25.96.224/28",
      "172.25.96.240/29",
      # TODO: below to be consumed into above when pre-stag is deprecated
    "172.25.96.248/29"]
    stag = ["172.23.96.224/27"]
    prod = ["172.21.96.224/27"]
  }

  pgsqlfs_subnet_cidr = {
    sbox = ["172.27.96.64/28"]
    devt = ["172.26.96.64/28",
    "172.26.96.80/28"]
    test = ["172.25.96.64/28",
      "172.25.96.80/28",
    "172.25.96.96/28"]
    stag = ["172.23.96.64/28"]
    prod = ["172.21.96.64/28"]
  }

  tags = {
    "Environment" = var.environment_tags[terraform.workspace]
  }

  aks_subnet_address_prefix = {
    sbox = "10.86.125.0/24"
    devt = "10.86.48.0/22"
    test = "10.86.52.0/22"
    stag = "10.86.96.0/22"
    prod = "10.86.153.0/24" #"10.86.100.0/22" (For Production vNet Expansion)
  }
}

# Resource Group for app
resource "azurerm_resource_group" "rg_app" {
  name     = "rg-${local.location_prefix}-${terraform.workspace}-${var.pdu}-app"
  location = var.location

  tags = merge(var.tags, local.tags)
}
resource "azurerm_management_lock" "rg_app_lock" {
  name       = "${azurerm_resource_group.rg_app.name}-Lock-DoNotDelete"
  scope      = azurerm_resource_group.rg_app.id
  lock_level = "CanNotDelete"
  count      = terraform.workspace == "prod" && var.enable_locks == true ? 1 : 0
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "app" {
  name                            = "kv-${local.location_prefix}-${terraform.workspace}-${var.pdu}-t-app"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg_app.name
  sku_name                        = "premium"
  tenant_id                       = var.tenant_id
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = true
  enable_rbac_authorization       = false
  purge_protection_enabled        = false

  tags = merge(var.tags, local.tags)

  access_policy {
    tenant_id = var.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    # TODO: reduce these permissions when appropriate
    secret_permissions = [
      "Backup", "Delete", "Get", "List", "Purge", "Recover", "Restore", "Set"
    ]
  }

  access_policy {
    tenant_id = var.tenant_id
    object_id = azuread_service_principal.dwp_ad_spn.id
    # application_id = azuread_service_principal.dwp_ad_spn.application_id

    secret_permissions = [
      "Get", "Set", "Delete"
    ]
    certificate_permissions = [
      "Get"
    ]
  }

  access_policy {
    tenant_id = var.tenant_id
    object_id = azuread_group.dwp_pdu_contributor_group.id
    # application_id = azuread_service_principal.dwp_ad_spn.application_id

    secret_permissions = [
      "Get", "Set", "Delete"
    ]
  }
}

###
### Omilia Token
###

resource "random_password" "omilia_token" {
  count = length(local.cpenvprefix[terraform.workspace])

  length           = 36
  override_special = "-"
}

resource "azurerm_key_vault_secret" "omilia_token" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "omilia-${local.cpenvprefix[terraform.workspace][count.index]}token"
  value        = random_password.omilia_token[count.index].result
  key_vault_id = azurerm_key_vault.app.id
}

###
### Storage Account stuff
###

# Omilia Storage Account
# locals {
#   uks_shared_services_aks_subnet_name = {
#     sbox = "sub-uks-devt-int-aks"
#     devt = "sub-uks-devt-int-aks"
#     test = "sub-uks-test-int-aks"
#     stag = "sub-uks-stag-int-aks"
#     prod = "sub-uks-prod-int-aks"
#   }
# }
# data "azurerm_subnet" "subnet_ss_aks_uks" {
#   # count                 = terraform.workspace == "sbox" ? 0 : 1
#   name                 = local.uks_shared_services_aks_subnet_name[terraform.workspace]
#   virtual_network_name = local.uks_shared_services_aks_vnet_name[terraform.workspace]
#   resource_group_name  = local.uks_shared_services_aks_vnet_resourcegroup[terraform.workspace]
# }

resource "azurerm_storage_account" "omilia" {
  name                            = replace("str${local.location_prefix}${terraform.workspace}${var.pdu}omilia", "-", "")
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg_app.name
  account_tier                    = "Standard"
  account_kind                    = "StorageV2"
  account_replication_type        = "LRS"
  enable_https_traffic_only       = "true"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  # network_rules {
  #   default_action             = "Deny"
  #   virtual_network_subnet_ids = [data.azurerm_subnet.subnet_ss_aks_uks.id]
  # }

  tags = merge(var.tags, local.tags)
}

resource "azurerm_key_vault_secret" "storage_primary_access_key" {
  name         = "storage-primary-access-key"
  value        = azurerm_storage_account.omilia.primary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_key_vault_secret" "storage_secondary_access_key" {
  name         = "storage-secondary-access-key"
  value        = azurerm_storage_account.omilia.secondary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_storage_share" "omilia" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  storage_account_name = azurerm_storage_account.omilia.name

  quota = var.file_share_size["omilia"][terraform.workspace]
}

resource "azurerm_storage_account" "calls" {
  count                           = contains(local.call_storage_env, terraform.workspace) ? 1 : 0
  name                            = replace("str${local.location_prefix}${terraform.workspace}${var.pdu}calls", "-", "")
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg_app.name
  account_tier                    = "Standard"
  account_kind                    = "StorageV2"
  account_replication_type        = "LRS"
  enable_https_traffic_only       = "true"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  tags = merge(var.tags, local.tags)
}

resource "azurerm_key_vault_secret" "calls_storage_primary_access_key" {
  count        = contains(local.call_storage_env, terraform.workspace) ? 1 : 0
  name         = "calls-storage-primary-access-key"
  value        = azurerm_storage_account.calls[count.index].primary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_key_vault_secret" "calls-storage_secondary_access_key" {
  count        = contains(local.call_storage_env, terraform.workspace) ? 1 : 0
  name         = "calls-storage-secondary-access-key"
  value        = azurerm_storage_account.calls[count.index].secondary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_storage_share" "calls_storage" {
  count = contains(local.call_storage_env, terraform.workspace) ? 1 : 0
  name  = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-calls"
  storage_account_name = azurerm_storage_account.calls[count.index].name
  quota = 50
}

resource "null_resource" "set_calls_management_policy" {
  count = contains(local.call_storage_env, terraform.workspace) ? 1 : 0
  provisioner "local-exec" {
    command = <<-EOT
      az storage account management-policy create \
        --account-name ${azurerm_storage_account.calls[count.index].name} \
        --resource-group ${azurerm_resource_group.rg_app.name} \
        --policy '{
          "rules": [
            {
              "name": "Rule28DaysOld",
              "enabled": true,
              "type": "Lifecycle",
              "definition": {
                "actions": {
                  "baseBlob": {
                    "delete": {
                      "daysAfterModificationGreaterThan": 28
                    }
                  }
                },
                "filters": {
                  "blobTypes": [
                    "blockBlob"
                  ]
                }
              }
            }
          ]
        }'
    EOT
  }
  triggers = {
    storage_account_id = azurerm_storage_account.calls[count.index].id
  }

}

resource "azurerm_storage_container" "app_configuration" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-conf"
  storage_account_name = azurerm_storage_account.omilia.name
}

resource "azurerm_storage_container" "artefacts" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-artefacts"
  storage_account_name = azurerm_storage_account.omilia.name
}

resource "azurerm_storage_container" "default" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  storage_account_name = azurerm_storage_account.omilia.name
}

resource "azurerm_storage_container" "datasets" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-datasets"
  storage_account_name = azurerm_storage_account.omilia.name
}



# resource "azurerm_private_endpoint" "omilia_sa" {
#   name                = "ep-${local.location_prefix}-${terraform.workspace}-${var.pdu}-omilia-sa"
#   location            = var.location
#   resource_group_name = azurerm_resource_group.rg_app.name
#   subnet_id           = azurerm_subnet.fe02[0].id

#   private_service_connection {
#     name                           = "psc-omilia-sa"
#     private_connection_resource_id = azurerm_storage_account.omilia.id
#     subresource_names              = ["file"]
#     is_manual_connection           = false
#   }

#   tags = merge(var.tags, local.tags)
# }

# resource "azurerm_private_dns_a_record" "omilia_sa" {
#   name                = "omilia-sa"
#   zone_name           = azurerm_private_dns_zone.dns.name
#   resource_group_name = azurerm_resource_group.rg_core.name
#   ttl                 = 300
#   records             = [azurerm_private_endpoint.omilia_sa.private_service_connection[0].private_ip_address]
# }

# resource "azurerm_private_dns_zone" "app_sa" {
#   name                = "privatelink.file.core.windows.net"
#   resource_group_name = azurerm_resource_group.rg_app.name

#   tags = merge(var.tags, local.tags)
# }

# resource "azurerm_private_dns_a_record" "omilia_sa_privatelink" {
#   name                = azurerm_storage_account.omilia.name
#   zone_name           = azurerm_private_dns_zone.app_sa.name
#   resource_group_name = azurerm_resource_group.rg_app.name
#   ttl                 = 300
#   records             = [azurerm_private_endpoint.omilia_sa.private_service_connection[0].private_ip_address]
# }

# resource "azurerm_private_dns_zone_virtual_network_link" "core_sa_link" {
#   count                 = terraform.workspace == "sbox" ? 0 : 1

#   name                  = "core-sa-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
#   resource_group_name   = azurerm_resource_group.rg_app.name
#   private_dns_zone_name = azurerm_private_dns_zone.app_sa.name
#   virtual_network_id    = data.azurerm_virtual_network.vnet_dwp_shared_services_core_uks.id

#   tags = merge(var.tags, local.tags)
# }

###
### Sounds storage account
###

resource "azurerm_storage_account" "sounds" {
  name                            = replace("str${local.location_prefix}${terraform.workspace}${var.pdu}omiliasnd", "-", "")
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg_app.name
  account_kind                    = "FileStorage"
  account_tier                    = "Premium"
  account_replication_type        = "ZRS"
  enable_https_traffic_only       = "true"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  tags = merge(var.tags, local.tags)
}

resource "azurerm_key_vault_secret" "sounds_storage_primary_access_key" {
  name         = "sounds-storage-primary-access-key"
  value        = azurerm_storage_account.sounds.primary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_key_vault_secret" "sounds_storage_secondary_access_key" {
  name         = "sounds-storage-secondary-access-key"
  value        = azurerm_storage_account.sounds.secondary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_storage_share" "sounds" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  storage_account_name = azurerm_storage_account.sounds.name

  quota = var.file_share_size["recordings"][terraform.workspace]
}

###
### Dialogs storage account
###

resource "azurerm_storage_account" "dialogs" {
  name                            = replace("str${local.location_prefix}${terraform.workspace}${var.pdu}omiliadlg", "-", "")
  location                        = var.location
  resource_group_name             = azurerm_resource_group.rg_app.name
  account_kind                    = "FileStorage"
  account_tier                    = "Premium"
  account_replication_type        = "ZRS"
  enable_https_traffic_only       = "true"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  tags = merge(var.tags, local.tags)
}

resource "azurerm_key_vault_secret" "dialogs_storage_primary_access_key" {
  name         = "dialogs-storage-primary-access-key"
  value        = azurerm_storage_account.dialogs.primary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_key_vault_secret" "dialogs_storage_secondary_access_key" {
  name         = "dialogs-storage-secondary-access-key"
  value        = azurerm_storage_account.dialogs.secondary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_storage_share" "dialogs" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  storage_account_name = azurerm_storage_account.dialogs.name

  quota = var.file_share_size["logs"][terraform.workspace]
}

###
### Redis stuff
###

# Omilia Redis Cache
resource "azurerm_redis_cache" "omilia" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                          = "redis-${local.location_prefix}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-${var.pdu}-omilia"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.rg_app.name
  capacity                      = 1
  family                        = "P"
  sku_name                      = "Premium"
  subnet_id                     = azurerm_subnet.redis01[0].id
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  # private_static_ip_address = TBC

  redis_configuration {
  }

  tenant_settings = {}
  zones           = []

  tags = merge(var.tags, local.tags)
}

resource "azurerm_key_vault_secret" "redis_primary_access_key" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "redis-${local.cpenvprefix[terraform.workspace][count.index]}primary-access-key"
  value        = azurerm_redis_cache.omilia[count.index].primary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_key_vault_secret" "redis_secondary_access_key" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "redis-${local.cpenvprefix[terraform.workspace][count.index]}secondary-access-key"
  value        = azurerm_redis_cache.omilia[count.index].secondary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

###
### MySQL stuff
###

#


# Omilia MySQL Database
resource "azurerm_subnet" "mysqlfs" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "mysqlfs-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg_network.name
  address_prefixes = [
    local.mysqlfs_subnet_cidr[terraform.workspace][count.index]
  ]
  delegation {
    name = "mysql-fs-01"

    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_mysql_flexible_server" "omilia" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "mysqlfs-${local.location_prefix}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-${var.pdu}-omilia"
  resource_group_name = azurerm_resource_group.rg_app.name
  location            = var.location

  administrator_login    = local.app_mysql_admin_login
  administrator_password = random_password.mysql_admin_password[count.index].result

  backup_retention_days    = 35
  delegated_subnet_id      = azurerm_subnet.mysqlfs[count.index].id
  private_dns_zone_id      = azurerm_private_dns_zone.app_mysql_zone[count.index].id
  sku_name                 = "MO_Standard_E4ds_v4"
  zone                     = 1
  tags = merge(var.tags, local.tags)

  depends_on = [azurerm_private_dns_zone_virtual_network_link.app_mysql_link]
}

resource "azurerm_mysql_flexible_server_configuration" "mysql-fs-security" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "require_secure_transport"
  resource_group_name = azurerm_resource_group.rg_app.name
  server_name         = azurerm_mysql_flexible_server.omilia[count.index].name
  value               = "OFF"
}

resource "random_id" "mysql_admin_login_suffix" {
  byte_length = 4
}

resource "azurerm_key_vault_secret" "mysql_admin_login" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "mysql-${local.cpenvprefix[terraform.workspace][count.index]}admin-login"
  value        = local.app_mysql_admin_login
  key_vault_id = azurerm_key_vault.app.id
}

resource "random_password" "mysql_admin_password" {
  count = length(local.cpenvprefix[terraform.workspace])

  length           = 64
  override_special = "+/=@:.~" # Allowed by GitLab masking
}

resource "azurerm_key_vault_secret" "mysql_admin_password" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "mysql-${local.cpenvprefix[terraform.workspace][count.index]}admin-password"
  value        = random_password.mysql_admin_password[count.index].result
  key_vault_id = azurerm_key_vault.app.id
}

# adding a random string to keyloak password
# as some pods can't handle password starting with
# a special character
resource "random_string" "keycloak_password_prefix" {
  count = length(local.cpenvprefix[terraform.workspace])
  length = 1
  upper = true
  lower = true
  special = false
}

resource "random_password" "keycloak_password" {
  count = length(local.cpenvprefix[terraform.workspace])
  length           = 32
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "*"
}

resource "azurerm_key_vault_secret" "keycloak_password" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "keycloak-${local.cpenvprefix[terraform.workspace][count.index]}password"
  value        = "${random_string.keycloak_password_prefix[count.index].result}${random_password.keycloak_password[count.index].result}"
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_private_dns_zone" "app_mysql_zone" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "${var.pdu}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}${local.dnsenv[terraform.workspace]}mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.rg_app.name

  tags = merge(var.tags, local.tags)
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_mysql_link" {
  count = terraform.workspace == "sbox" ? 0 : length(local.cpenvprefix[terraform.workspace])

  name                  = "aks-mysql-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  resource_group_name   = azurerm_resource_group.rg_app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_mysql_zone[count.index].name
  virtual_network_id    = data.azurerm_virtual_network.vnet_dwp_shared_services_core_uks.id

  tags = merge(var.tags, local.tags)
}

resource "azurerm_private_dns_zone_virtual_network_link" "vpn_mysql_link" {
  count = terraform.workspace == "sbox" ? 0 : length(local.cpenvprefix[terraform.workspace])

  name                  = "vpn-mysql-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  resource_group_name   = azurerm_resource_group.rg_app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_mysql_zone[count.index].name
  virtual_network_id    = data.azurerm_virtual_network.vnet_dwp_shared_services_vpn_uks.id

  tags = merge(var.tags, local.tags)
}

resource "azurerm_private_dns_zone_virtual_network_link" "app_mysql_link" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                  = "app-mysql-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  resource_group_name   = azurerm_resource_group.rg_app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_mysql_zone[count.index].name
  virtual_network_id    = azurerm_virtual_network.vnet.id

  tags = merge(var.tags, local.tags)
}

resource "azurerm_network_security_group" "mysqlfs" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "nsg-${local.location_prefix}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-${var.pdu}-mysqlfs"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_app.name

  security_rule {
    name                       = "from-ss-aks-int"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.aks_subnet_address_prefix[terraform.workspace]
    destination_address_prefix = local.mysqlfs_subnet_cidr[terraform.workspace][count.index]
  }

  tags = merge(var.tags, local.tags)

  provisioner "local-exec" {
    command = <<EOF
      az network watcher flow-log create \
      --nsg ${self.id} \
      --location ${var.location} \
      --name ${self.name} \
      --storage-account ${azurerm_storage_account.nsg_logs_account.id} \
      --workspace ${azurerm_log_analytics_workspace.oms.id} \
      --enabled true --format JSON --log-version 2 --retention 365 \
      --traffic-analytics true
    EOF
  }

  provisioner "local-exec" {
    command = <<EOF
      az monitor diagnostic-settings create \
      --name nsg-diagnostics \
      --resource ${self.id} \
      --workspace ${azurerm_log_analytics_workspace.oms.id} \
      --logs '[ { "category": "NetworkSecurityGroupEvent", "enabled": true }, { "category": "NetworkSecurityGroupRuleCounter", "enabled": true } ]'
    EOF
  }
}

resource "azurerm_subnet_network_security_group_association" "mysqlfs" {
  count = length(local.cpenvprefix[terraform.workspace])

  subnet_id                 = azurerm_subnet.mysqlfs[count.index].id
  network_security_group_id = azurerm_network_security_group.mysqlfs[count.index].id
}

resource "azurerm_mysql_flexible_server" "replica" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "mysqlfsreplica-${local.location_prefix}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-${var.pdu}-omilia"
  resource_group_name = azurerm_resource_group.rg_app.name
  location            = var.location

  administrator_login    = local.app_mysql_admin_login
  administrator_password = random_password.mysql_admin_password[count.index].result

  create_mode      = "Replica"
  source_server_id = azurerm_mysql_flexible_server.omilia[count.index].id

  backup_retention_days = 35
  delegated_subnet_id   = azurerm_subnet.mysqlfs[count.index].id
  private_dns_zone_id   = azurerm_private_dns_zone.app_mysql_zone[count.index].id
  sku_name              = "MO_Standard_E4ds_v4"
  zone                  = 1

  lifecycle {
    ignore_changes = [zone]
  }

  tags = merge(var.tags, local.tags)

  depends_on = [azurerm_private_dns_zone_virtual_network_link.app_mysql_link]
}

resource "azurerm_mysql_flexible_server_configuration" "replica_server_config" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "require_secure_transport"
  resource_group_name = azurerm_resource_group.rg_app.name
  server_name         = azurerm_mysql_flexible_server.replica[count.index].name
  value               = "OFF"
}

###
### pgsql stuff
###

# Omilia pgsql Database
resource "azurerm_subnet" "pgsqlfs" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                 = "pgsqlfs-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  virtual_network_name = azurerm_virtual_network.vnet.name
  resource_group_name  = azurerm_resource_group.rg_network.name
  address_prefixes = [
    local.pgsqlfs_subnet_cidr[terraform.workspace][count.index]
  ]
  delegation {
    name = "pgsql-fs-01"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_postgresql_flexible_server" "omilia" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "pgsqlfs-${local.location_prefix}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-${var.pdu}-omilia"
  resource_group_name = azurerm_resource_group.rg_app.name
  location            = var.location

  administrator_login    = local.app_pgsql_admin_login
  administrator_password = random_password.pgsql_admin_password[count.index].result

  version    = 13
  storage_mb = 32768
  zone       = 1

  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = 3
  }

  lifecycle {
    ignore_changes = [
      zone,
      high_availability.0.standby_availability_zone
    ]
  }

  backup_retention_days = 35
  delegated_subnet_id   = azurerm_subnet.pgsqlfs[count.index].id
  private_dns_zone_id   = azurerm_private_dns_zone.app_pgsql_zone[count.index].id
  sku_name              = "GP_Standard_D2ds_v4"

  tags = merge(var.tags, local.tags)

  depends_on = [azurerm_private_dns_zone_virtual_network_link.app_pgsql_link]
}

# TODO: workaround due to below bug
# https://github.com/hashicorp/terraform-provider-azurerm/issues/16010
# https://github.com/hashicorp/terraform-provider-azurerm/issues/16010#issuecomment-1362859956
data "external" "pgsql_fqdn" {
  count = length(local.cpenvprefix[terraform.workspace])

  program = ["./fetch_first_a_record_fqdn.sh"]

  query = {
    resource_group_name = azurerm_private_dns_zone.app_pgsql_zone[count.index].resource_group_name
    zone_name           = azurerm_private_dns_zone.app_pgsql_zone[count.index].name
  }
}

resource "azurerm_key_vault_secret" "pgsql_hostname" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "pgsql-${local.cpenvprefix[terraform.workspace][count.index]}hostname"
  value        = data.external.pgsql_fqdn[count.index].result.fqdn
  key_vault_id = azurerm_key_vault.app.id
}

resource "random_id" "pgsql_admin_login_suffix" {
  byte_length = 4
}

resource "azurerm_key_vault_secret" "pgsql_admin_login" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "pgsql-${local.cpenvprefix[terraform.workspace][count.index]}admin-login"
  value        = local.app_pgsql_admin_login
  key_vault_id = azurerm_key_vault.app.id
}

resource "random_password" "pgsql_admin_password" {
  count = length(local.cpenvprefix[terraform.workspace])

  length           = 64
  override_special = "+/=@:.~" # Allowed by GitLab masking
}

resource "azurerm_key_vault_secret" "pgsql_admin_password" {
  count = length(local.cpenvprefix[terraform.workspace])

  name         = "pgsql-${local.cpenvprefix[terraform.workspace][count.index]}admin-password"
  value        = random_password.pgsql_admin_password[count.index].result
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_private_dns_zone" "app_pgsql_zone" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "${var.pdu}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}${local.dnsenv[terraform.workspace]}postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg_app.name

  tags = merge(var.tags, local.tags)
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks_pgsql_link" {
  count = terraform.workspace == "sbox" ? 0 : length(local.cpenvprefix[terraform.workspace])

  name                  = "aks-pgsql-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  resource_group_name   = azurerm_resource_group.rg_app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_pgsql_zone[count.index].name
  virtual_network_id    = data.azurerm_virtual_network.vnet_dwp_shared_services_core_uks.id

  tags = merge(var.tags, local.tags)
}

resource "azurerm_private_dns_zone_virtual_network_link" "vpn_pgsql_link" {
  count = terraform.workspace == "sbox" ? 0 : length(local.cpenvprefix[terraform.workspace])

  name                  = "vpn-pgsql-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  resource_group_name   = azurerm_resource_group.rg_app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_pgsql_zone[count.index].name
  virtual_network_id    = data.azurerm_virtual_network.vnet_dwp_shared_services_vpn_uks.id

  tags = merge(var.tags, local.tags)
}

resource "azurerm_private_dns_zone_virtual_network_link" "app_pgsql_link" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                  = "app-pgsql-link-${azurerm_virtual_network.vnet.name}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}"
  resource_group_name   = azurerm_resource_group.rg_app.name
  private_dns_zone_name = azurerm_private_dns_zone.app_pgsql_zone[count.index].name
  virtual_network_id    = azurerm_virtual_network.vnet.id

  tags = merge(var.tags, local.tags)
}

resource "azurerm_network_security_group" "pgsqlfs" {
  count = length(local.cpenvprefix[terraform.workspace])

  name                = "nsg-${local.location_prefix}-${local.cpenvprefix[terraform.workspace][count.index]}${terraform.workspace}-${var.pdu}-pgsqlfs"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_app.name

  security_rule {
    name                       = "from-ss-aks-int"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = local.aks_subnet_address_prefix[terraform.workspace]
    destination_address_prefix = local.pgsqlfs_subnet_cidr[terraform.workspace][count.index]
  }

  tags = merge(var.tags, local.tags)

  provisioner "local-exec" {
    command = <<EOF
      az network watcher flow-log create \
      --nsg ${self.id} \
      --location ${var.location} \
      --name ${self.name} \
      --storage-account ${azurerm_storage_account.nsg_logs_account.id} \
      --workspace ${azurerm_log_analytics_workspace.oms.id} \
      --enabled true --format JSON --log-version 2 --retention 365 \
      --traffic-analytics true
    EOF
  }

  provisioner "local-exec" {
    command = <<EOF
      az monitor diagnostic-settings create \
      --name nsg-diagnostics \
      --resource ${self.id} \
      --resource-group ${azurerm_resource_group.rg_app.id} \
      --workspace ${azurerm_log_analytics_workspace.oms.id} \
      --logs '[ { "category": "NetworkSecurityGroupEvent", "enabled": true }, { "category": "NetworkSecurityGroupRuleCounter", "enabled": true } ]'
    EOF
  }
}

resource "azurerm_subnet_network_security_group_association" "pgsqlfs" {
  count = length(local.cpenvprefix[terraform.workspace])

  subnet_id                 = azurerm_subnet.pgsqlfs[count.index].id
  network_security_group_id = azurerm_network_security_group.pgsqlfs[count.index].id
}

##
## TTS stuff
##

resource "azurerm_cognitive_account" "tts" {
  name                               = "tts-${local.location_prefix}-${terraform.workspace}-${var.pdu}"
  location                           = var.location
  resource_group_name                = azurerm_resource_group.rg_app.name
  kind                               = "SpeechServices"
  sku_name                           = "S0"
  public_network_access_enabled      = false
  outbound_network_access_restricted = false
  custom_subdomain_name              = "tts-${local.location_prefix}-${terraform.workspace}-${var.pdu}"

  network_acls {
    default_action = "Deny"

    virtual_network_rules {
      subnet_id = azurerm_subnet.fe02[0].id
    }
  }
  tags = merge(var.tags, local.tags)
}

resource "azurerm_key_vault_secret" "tts_primary_access_key" {
  name         = "tts-primary-access-key"
  value        = azurerm_cognitive_account.tts.primary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_key_vault_secret" "tts_secondary_access_key" {
  name         = "tts-secondary-access-key"
  value        = azurerm_cognitive_account.tts.secondary_access_key
  key_vault_id = azurerm_key_vault.app.id
}

# Disable because the value is not set until after the ep is deployed
# hence the TF fails to validate - bad design in azurerm_private_endpoint
# resource "azurerm_key_vault_secret" "tts_pep_fqdn" {
#   name         = "tts-pep-fqdn"
#   value        = azurerm_private_endpoint.tts.private_dns_zone_configs[0].record_sets[0].fqdn
#   key_vault_id = azurerm_key_vault.app.id
# }

# TTS Networking devt
resource "azurerm_private_endpoint" "tts_pep" {
  name                = "ep-${local.location_prefix}-${terraform.workspace}-${var.pdu}-tts"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_app.name
  subnet_id           = azurerm_subnet.fe02[0].id

  private_service_connection {
    name                           = "psc-tts-${terraform.workspace}"
    private_connection_resource_id = azurerm_cognitive_account.tts.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "tts-dzg-${terraform.workspace}"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.tts.id]
  }
  tags = merge(var.tags, local.tags)
}

data "azurerm_private_dns_zone" "tts" {
  name                 = "privatelink.cognitiveservices.azure.com"
  resource_group_name  = local.uks_shared_services_dns_resourcegroup[terraform.workspace]
  provider             = azurerm.shared_services_uks
}

###
### Analytics server
###

locals {
  analytics_vm_name = "uksuccanalytics"

  uks_shared_services_gallery_name = {
    sbox = "GoldImagesDevGallery"
    devt = "GoldImagesDevGallery"
    test = "GoldImagesDevGallery"
    stag = "GoldImagesGallery"
    prod = "GoldImagesGallery"
  }

  uks_shared_services_rg_name = {
    sbox = "rg-dwp-dev-ss-shared-images"
    devt = "rg-dwp-dev-ss-shared-images"
    test = "rg-dwp-dev-ss-shared-images"
    stag = "rg-dwp-prd-ss-shared-images"
    prod = "rg-dwp-prd-ss-shared-images"
  }
}

data "azurerm_shared_image_version" "latestgoldimage" {
  name                = "latest"
  image_name          = "RHEL7-CIS2"
  gallery_name        = local.uks_shared_services_gallery_name[terraform.workspace]
  resource_group_name = local.uks_shared_services_rg_name[terraform.workspace]
  # Specify image is in a different subscription
  provider = azurerm.shared_services_uks
}

# golden/hardened image for win vm deployment for shir
data "azurerm_shared_image_version" "win2019_latestGoldImage" {
  name                = "latest"
  image_name          = "WIN2019-CIS2"
  gallery_name        = local.uks_shared_services_gallery_name[terraform.workspace]
  resource_group_name = local.uks_shared_services_rg_name[terraform.workspace]
  # Specify image is in a different subscription
  provider = azurerm.shared_services_uks
}
# Resource Group for analytics
resource "azurerm_resource_group" "rg_analytics" {
  name     = "rg-${local.location_prefix}-${terraform.workspace}-${var.pdu}-analytics"
  location = var.location
  tags     = merge(var.tags, local.tags)
  count    = contains(local.build_tableau, terraform.workspace) ? 1 : 0
}
resource "azurerm_management_lock" "rg_analytics_lock" {
  name       = "${azurerm_resource_group.rg_analytics[0].name}-Lock-DoNotDelete"
  scope      = azurerm_resource_group.rg_analytics[0].id
  lock_level = "CanNotDelete"
  count      = contains(local.tableau_lock, terraform.workspace) ? 1 : 0
}

resource "random_password" "analytics_admin_password" {
  count = contains(local.build_tableau, terraform.workspace) ? 1 : 0
  length           = 32
  override_special = "+/=@:.~" # Allowed by GitLab masking
}

resource "azurerm_key_vault_secret" "analytics_admin_password" {
  count = contains(local.build_tableau, terraform.workspace) ? 1 : 0
  name         = "analytics-admin-password"
  value        = random_password.analytics_admin_password[0].result
  key_vault_id = azurerm_key_vault.app.id
}

resource "azurerm_managed_disk" "analytics_data" {
  count = contains(local.build_tableau, terraform.workspace) ? 1 : 0
  name                 = "${local.analytics_vm_name}_disk1"
  location             = var.location
  create_option        = "Empty"
  disk_size_gb         = 100
  resource_group_name  = azurerm_resource_group.rg_analytics[0].name
  storage_account_type = "Premium_LRS"
  tags = merge(var.tags, local.tags)
}

resource "azurerm_network_interface" "analytics" {
  count               = contains(local.build_tableau, terraform.workspace) ? 1 : 0
  name                = "${local.analytics_vm_name}_nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_analytics[0].name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.fe02[0].id
    private_ip_address_allocation = "Dynamic"
  }

  tags = merge(var.tags, local.tags)
}

resource "azurerm_storage_account" "boot_diagnostics" {
  name                      = replace("strdwp${terraform.workspace}${var.pdu}diag", "-", "")
  location                  = var.location
  resource_group_name       = azurerm_resource_group.rg_app.name
  account_tier              = "Standard"
  account_kind              = "StorageV2"
  account_replication_type  = "LRS"
  enable_https_traffic_only = "true"

  tags = merge(var.tags, local.tags)
}

resource "azurerm_virtual_machine" "analytics" {
  count = contains(local.build_tableau, terraform.workspace) ? 1 : 0

  name                = local.analytics_vm_name
  resource_group_name = azurerm_resource_group.rg_analytics[0].name
  location            = var.location
  vm_size             = "Standard_E16s_v5"
  network_interface_ids = [
    azurerm_network_interface.analytics[0].id,
  ]

  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.boot_diagnostics.primary_blob_endpoint
  }

  # lifecycle {
  #   # Tableau license needs to be deactivated first.
  #   # Do not use a Destroy-Time Provisioners as they are ignored
  #   # for tainted resources, which is an accident waiting happen.
  #   prevent_destroy = true
  # }

  # TODO: consider whether os_disk would be useful if
  # a license activated server was deleted accidentally
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = false

  os_profile {
    computer_name  = local.analytics_vm_name
    admin_username = "azureuser"

    custom_data = <<-CUSTOM_DATA
    #!/bin/bash
    set -e
    echo "Setting up Tableau"
    # Assume data disk is sdb
    # if not perhaps use "lsblk | grep disk | grep 100G" ...
    parted /dev/sdb --script mklabel gpt mkpart xfspart xfs 0% 100%
    mkfs.xfs /dev/sdb1
    partprobe /dev/sdb1
    mkdir /var/opt/tableau
    echo /dev/sdb1 /var/opt/tableau/ xfs   defaults,nofail   1   2 >> /etc/fstab
    mount /var/opt/tableau/
    df -k

    # IPTABLES on Gold Images
    iptables -I INPUT 4 -p tcp -m state --state NEW -m tcp --dport 8850 -j ACCEPT
    iptables -I INPUT 4 -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT
    iptables-save > /etc/sysconfig/iptables
    # For CentOS 7.9
    # firewall-cmd --zone=public --add-port=8850/tcp
    # firewall-cmd --zone=public --add-port=80/tcp

    cd /var/opt/tableau/
    wget https://downloads.tableau.com/esdalt/2023.1.11/tableau-server-2023-1-11.x86_64.rpm
    yum -y update
    yum -y install tableau-server-2023-1-11.x86_64.rpm
    counter=0
    while [ $? -ne 0 ]; do [[ counter -eq 3 ]] && exit 1; ((counter++)); !!; done
    /opt/tableau/tableau_server/packages/scripts.20231.24.0312.1557/initialize-tsm -f --accepteula -a azureuser
    # https://uksuccanalytics.dc-cnv-devt.np.az.dwpcloud.uk:8850/
    # To access use azureuser credentials (requires local passwd)
    source /etc/profile.d/tableau_server.sh
    # offline : TSXX-52E4-FEC0-A036-FB03
    # online : TS16-5288-86E0-330F-C99D
    # above also provided but only have 10 viewers so...
    tsm licenses activate -k TS16-5288-86E0-330F-C99D
    cat << EOF > reg.json
    {
        "first_name" : "Ioannis",
        "last_name" : "Nikolaidis",
        "phone" : "2106930664",
        "email" : "support@omilia.com",
        "company" : "Omilia Ltd 01",
        "industry" : "",
        "company_employees" : "1-10",
        "department" : "Analytics",
        "title" : "Director",
        "city" : "Larnaca",
        "state" : "CY",
        "zip" : "6042",
        "country" : "CY",
        "opt_in" : "false",
        "eula" : "true"
    }
    EOF
    tsm register --file reg.json
    tsm settings import -f /opt/tableau/tableau_server/packages/scripts.20231.24.0312.1557/config.json
    tsm pending-changes apply
    tsm initialize --start-server --request-timeout 1800
    tabcmd initialuser --server "$(hostname):80" --username 'admin' --password '${random_password.analytics_admin_password[0].result}'
    # http://uksuccanalytics.dc-cnv-devt.np.az.dwpcloud.uk/
    wget https://dev.mysql.com/get/Downloads/Connector-ODBC/8.0/mysql-connector-odbc-8.0.32-1.el7.x86_64.rpm
    yum -y install mysql-connector-odbc-8.0.32-1.el7.x86_64.rpm
    wget https://downloads.tableau.com/drivers/linux/postgresql/postgresql-42.3.3.jar
    mkdir -p /opt/tableau/tableau_driver/jdbc
    mv postgresql-42.3.3.jar /opt/tableau/tableau_driver/jdbc
    tsm restart
    sudo yum install -y cronie
    sudo echo '* 3 * * * root /opt/tableau/tableau_server/packages/customer-bin.20231.24.0312.1557/tsm maintenance cleanup --all --log-files-retention 3 --http-requests-table-retention 3' | sudo tee /etc/cron.d/analytics-cronjob
    sudo chmod 0644 /etc/cron.d/analytics-cronjob
    sudo systemctl restart crond
    CUSTOM_DATA
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCs472hnctUTzVhpDo+07BEivsmooNeEjX8SRjV5/mzu6tpK2I/K96ZvUgAAH4RrduFNXY9F+d/qK9dww5/wPYgqPncQQYBstM3y7rjAMT72JLozYZ244evOS/drj2zV0zei5N+HxUab+ovSLllATLyF5zVAwG5XTLRXzsbR2MByN7QOB0Xzb2a7yM0ks6+vg5FF4yqABFKHJv0H7SuScxSjh2gZScWsgNZKwMGHKd8f8KIEzXpz8+JppiuHBaFm9boVRElWp5cHKrwqcPaldx28o/gwt/C6mS+71sSqlcTG6NJ61wJV9z7jTiZFrL3kbqfHisZyLdev3WUklfCvd4ArjZFxAzy5DNpQdSVZQrugJyhM+U4SZ/AUBBr7QqyALzVISIXFqMRBBOfCxRSmpaIu/7FI8moY/pvnoWXSapg61+92M6I9lWHJwfYtF0XWUZknTz2S6gNk5b+EefJPY7lhFPtn5NPQNyZ5iJMlJ/QJZDjLAC9jufTxh+wxQW6K9U= generated-by-azure"
      path     = "/home/azureuser/.ssh/authorized_keys"
    }
  }

  storage_data_disk {
    name            = azurerm_managed_disk.analytics_data[0].name
    caching         = "ReadWrite"
    create_option   = "Attach"
    lun             = 10
    managed_disk_id = azurerm_managed_disk.analytics_data[0].id
    disk_size_gb    = azurerm_managed_disk.analytics_data[0].disk_size_gb
  }

  storage_os_disk {
    name              = "${local.analytics_vm_name}_osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }

  storage_image_reference {
    id = data.azurerm_shared_image_version.latestgoldimage.id
  }

  tags = merge(var.tags, local.tags, {
    "Persistence" = "Ignore"
  })
}

###
### SIPP server
###

locals {
  sipp_vm_name = "uksuccsipp"
}

data "azurerm_shared_image_version" "latestRHEL8goldimage" {
  name                = "latest"
  image_name          = "RHEL8-CIS2"
  gallery_name        = local.uks_shared_services_gallery_name[terraform.workspace]
  resource_group_name = local.uks_shared_services_rg_name[terraform.workspace]
  # Specify image is in a different subscription
  provider = azurerm.shared_services_uks
}

resource "azurerm_network_interface" "sipp" {
  name                = "${local.sipp_vm_name}_nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_app.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.fe02[0].id
    private_ip_address_allocation = "Dynamic"
  }

  tags = merge(var.tags, local.tags)
}

resource "azurerm_virtual_machine" "sipp" {
  name                = local.sipp_vm_name
  resource_group_name = azurerm_resource_group.rg_app.name
  location            = var.location
  vm_size             = "Standard_F4s_v2"
  network_interface_ids = [
    azurerm_network_interface.sipp.id,
  ]

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {
    enabled     = true
    storage_uri = azurerm_storage_account.boot_diagnostics.primary_blob_endpoint
  }

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  storage_os_disk {
    name              = "${local.sipp_vm_name}_osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }

  storage_image_reference {
    id = data.azurerm_shared_image_version.latestRHEL8goldimage.id
  }

  os_profile {
    computer_name  = local.sipp_vm_name
    admin_username = "azureuser"

    custom_data = <<-CUSTOM_DATA
    #!/bin/bash
    set -e

    # # IPTABLES on Gold Images
    # iptables -I INPUT 4 -p tcp -m state --state NEW -m tcp --dport 80 -j ACCEPT
    # iptables-save > /etc/sysconfig/iptables

    echo '*** INSTALL SIPP PRE-REQS ***'    
    until yum -y install cmake gcc-c++ openssl-devel ncurses-devel git lksctp-tools-devel libpcap-devel
    do
      echo "Try again in 10..."
      sleep 10
    done
    echo '*** BUILD SIPP ***'
    # curl -LO https://github.com/SIPp/sipp/releases/download/v3.7.0_rc1/sipp-3.7.0.rc1.tar.gz
    # tar xzf sipp-3.7.0.rc1.tar.gz
    # cd sipp-3.7.0~rc1/
    # cat <<EOF > CMakeLists.txt.patch
    # --- CMakeLists.txt
    # +++ CMakeLists.txt_fix
    # @@ -160,7 +160,7 @@
    #    if(CURSES_LIBRARY_FOUND)
    #      set(CURSES_LIBRARY \$${CURSES_LIBRARY_LIBRARIES})
    #    endif()
    # -  pkg_search_module(TINFO_LIBRARY tinfo)
    # +  pkg_search_module(TINFO_LIBRARY tinfo ncursesw)
    #    if(TINFO_LIBRARY_FOUND)
    #      set(TINFO_LIBRARY \$${TINFO_LIBRARY_LIBRARIES})
    #    endif()
    # EOF
    # patch < CMakeLists.txt.patch
    dnf install automake autoconf gsl-devel -y
    curl -LO https://github.com/SIPp/sipp/releases/download/v3.7.1/sipp-3.7.1.tar.gz
    tar xzf sipp-3.7.1.tar.gz
    cd sipp-3.7.1/
    ./build.sh --full
    # git clone https://github.com/google/googletest gtest
    make install
    cd ..
    curl -LO https://github.com/SIPp/sipp/releases/download/v3.6.0/sipp-3.6.0.tar.gz
    tar xzf sipp-3.6.0.tar.gz
    cd sipp-3.6.0/
    ./build.sh --full
    make install
    cd ..
    cp -r sipp-3.7.1 /usr/local/bin
    sudo chmod a+x /usr/local/bin/sipp-3.7.1
    sudo chmod a+x /usr/local/bin/sipp-3.7.1/sipp
    cd /
    sipp -h

    # yum -y install lksctp-tools
    # curl -O https://kojipkgs.fedoraproject.org//packages/sipp/3.7.0/2.fc39/x86_64/sipp-3.7.0-2.fc39.x86_64.rpm
    # rpm -Uvh sipp-3.7.0-2.fc39.x86_64.rpm
    # yum -y install sipp
    CUSTOM_DATA
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCs472hnctUTzVhpDo+07BEivsmooNeEjX8SRjV5/mzu6tpK2I/K96ZvUgAAH4RrduFNXY9F+d/qK9dww5/wPYgqPncQQYBstM3y7rjAMT72JLozYZ244evOS/drj2zV0zei5N+HxUab+ovSLllATLyF5zVAwG5XTLRXzsbR2MByN7QOB0Xzb2a7yM0ks6+vg5FF4yqABFKHJv0H7SuScxSjh2gZScWsgNZKwMGHKd8f8KIEzXpz8+JppiuHBaFm9boVRElWp5cHKrwqcPaldx28o/gwt/C6mS+71sSqlcTG6NJ61wJV9z7jTiZFrL3kbqfHisZyLdev3WUklfCvd4ArjZFxAzy5DNpQdSVZQrugJyhM+U4SZ/AUBBr7QqyALzVISIXFqMRBBOfCxRSmpaIu/7FI8moY/pvnoWXSapg61+92M6I9lWHJwfYtF0XWUZknTz2S6gNk5b+EefJPY7lhFPtn5NPQNyZ5iJMlJ/QJZDjLAC9jufTxh+wxQW6K9U= generated-by-azure"
      path     = "/home/azureuser/.ssh/authorized_keys"
    }
  }

  tags = merge(var.tags, local.tags, {
    "Persistence" = "Ignore"
  })
}

# resource "azurerm_role_assignment" "sipp_role" {
#   principal_id         = azurerm_virtual_machine.sipp.identity[0].principal_id
#   scope                = azurerm_storage_account.boot_diagnostics.id
#   role_definition_name = "Storage Blob Data Contributor"
# }

# resource "azurerm_virtual_machine_extension" "configure-cron" {
#   name                 = "configure-cron"
#   publisher            = "Microsoft.Azure.Extensions"
#   type                 = "CustomScript"
#   type_handler_version = "2.0"
#   virtual_machine_id   = azurerm_virtual_machine.sipp.id
#   protected_settings = jsonencode(
#     {
#       "script" : "${base64encode(templatefile("${path.module}/templates/configure-cron.sh", {
#         lb_ip         = var.lb_ip[terraform.workspace],
#         # file          = var.sipp_file,
#         # accountname   = azurerm_storage_account.boot_diagnostics.name
#       }))}"
#     }
#   )
#   depends_on = [azurerm_role_assignment.sipp_role]
# }

# resource "azurerm_monitor_scheduled_query_rules_alert_v2" "sipp-alert" {
#   name                = "[DWP_NGCC][Next Generation Contact Centre (current PSN-CC service)] Conversational Platform is down"
#   resource_group_name = azurerm_resource_group.rg_app.name
#   location            = azurerm_resource_group.rg_app.location

#   evaluation_frequency = "PT5M"
#   window_duration      = "PT5M"
#   scopes               = [azurerm_virtual_machine.sipp.id]
#   severity             = 3
#   criteria {
#     query                   = <<-QUERY
#       ConfigurationChange | where ConfigChangeType == "Files" and FileSystemPath contains "/tmp/sipp.flag" and ChangeCategory == "Added"
#       QUERY
#     time_aggregation_method = "Maximum"
#     threshold               = 0
#     operator                = "GreaterThan"

#     dimension {
#       name     = "Computer"
#       operator = "Include"
#       values   = ["*"]
#     }
#     failing_periods {
#       minimum_failing_periods_to_trigger_alert = 1
#       number_of_evaluation_periods             = 1
#     }
#   }

#   auto_mitigation_enabled          = true
#   workspace_alerts_storage_enabled = false
#   description                      = "sipp-alert"
#   display_name                     = "sipp-alert"
#   enabled                          = true
#   query_time_range_override        = "PT30M"
#   skip_query_validation            = true
#   action {
#     action_groups = [azurerm_monitor_action_group.action_group_sre_dwp.id]
#   }
# }
variable "lb_ip" {}



