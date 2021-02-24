resource "azurerm_storage_account" "dev-api-storage_account" {
  name                      = var.sa_name
  resource_group_name       = var.azurerm_resource_group_name
  location                  = var.location
  account_kind              = var.account_kind
  account_tier              = "STANDARD"
  account_replication_type  = "LRS"
  access_tier               = "hot"
  enable_https_traffic_only = var.https_traffic
  is_hns_enabled            = var.is_hns_enabled
  allow_blob_public_access  = var.allow_blob_public_access

  tags = var.tags

  dynamic network_rules {
    for_each = var.network_rules
    content {
      default_action           = network_rules.value.default_action
      bypass                   = network_rules.value.bypass
      ip_rules                 = network_rules.value.ip_rules
      virtual_network_subnet_ids = network_rules.value.virtual_network_subnet_ids
    }
  }

  dynamic blob_properties {
    for_each = var.blob_properties_cors_rules
    content {
      cors_rule {
        allowed_headers         = blob_properties.value.allowed_headers
        allowed_methods         = blob_properties.value.allowed_methods
        allowed_origins         = blob_properties.value.allowed_origins
        exposed_headers         = blob_properties.value.exposed_headers
        max_age_in_seconds      = blob_properties.value.max_age_in_seconds
      }
    }
  }
}

resource "azurerm_storage_management_policy" "management_policy" {
  count              =  var.add_lifecycle_rules ? 1 : 0
  storage_account_id = azurerm_storage_account.dev-api-storage_account.id
  dynamic rule {
    for_each = var.lifcecycle_rules
    content {
      name = rule.value.name
      enabled = rule.value.enabled
      filters {
        prefix_match = rule.value.prefix_match
        blob_types = rule.value.blob_types
      }
      actions {
        base_blob {
          tier_to_cool_after_days_since_modification_greater_than = rule.value.tier_to_cool_after_days_since_modification_greater_than
          tier_to_archive_after_days_since_modification_greater_than = rule.value.tier_to_archive_after_days_since_modification_greater_than
          delete_after_days_since_modification_greater_than = rule.value.delete_after_days_since_modification_greater_than
        }
        snapshot {
          delete_after_days_since_creation_greater_than = rule.value.delete_snapshot_after_days_since_creation_greater_than
        }
      }
    }
  }
}

resource "azurerm_storage_container" "dev-api-storage-container" {
  depends_on = [azurerm_storage_account.dev-api-storage_account]
  count                 = length(var.containers)
  name                  = var.containers[count.index].name
  storage_account_name  = azurerm_storage_account.dev-api-storage_account.name
  container_access_type = var.containers[count.index].access_type
}

resource "azurerm_storage_share" "dev-api-storage-share" {
  count                = length(var.shares)
  name                 = var.shares[count.index].name
  storage_account_name = azurerm_storage_account.dev-api-storage_account.name
  quota                = var.shares[count.index].quota
}