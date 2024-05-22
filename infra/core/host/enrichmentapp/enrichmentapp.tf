data "local_file" "image_tag" {
  filename = "../container_images/enrichment_container_image/image_tag.txt"
}

locals {
  sanitised_container_name = replace(var.container_name, "_", "")
  stripped_container_registry = replace(var.container_registry, "https://", "")
}

resource "null_resource" "docker_push" {
  provisioner "local-exec" {
    command = <<-EOT
        printf "%s" ${var.container_registry_admin_password} | docker login --username ${var.container_registry_admin_username} --password-stdin ${var.container_registry}
        docker tag enrichment_container_image ${local.stripped_container_registry}/enrichment_container_image:${data.local_file.image_tag.content}
        docker push ${local.stripped_container_registry}/enrichment_container_image:${data.local_file.image_tag.content}
      EOT
  }
  triggers = {
    always_run = timestamp()
  }
}

// Create Enrichment App Service Plan 
resource "azurerm_service_plan" "appServicePlan" {
  name                          = var.plan_name
  location                      = var.location
  resource_group_name           = var.resourceGroupName
  sku_name                      = var.sku["size"]
  worker_count                  = var.sku["capacity"]
  os_type                       = "Linux"
  tags                          = var.tags
  per_site_scaling_enabled      = false
  zone_balancing_enabled        = false
}

resource "azurerm_monitor_autoscale_setting" "scaleout" {
  name                = azurerm_service_plan.appServicePlan.name
  resource_group_name = var.resourceGroupName
  location            = var.location
  target_resource_id  = azurerm_service_plan.appServicePlan.id

  profile {
    name = "Scale out condition"
    capacity {
      default = 1
      minimum = 1
      maximum = 5
    }

    rule {
      metric_trigger {
        metric_name         = "CpuPercentage"
        metric_resource_id  = azurerm_service_plan.appServicePlan.id
        time_grain          = "PT1M"
        statistic           = "Average"
        time_window         = "PT5M"
        time_aggregation    = "Average"
        operator            = "GreaterThan"
        threshold           = 60
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name         = "CpuPercentage"
        metric_resource_id  = azurerm_service_plan.appServicePlan.id
        time_grain          = "PT1M"
        statistic           = "Average"
        time_window         = "PT10M"
        time_aggregation    = "Average"
        operator            = "LessThan"
        threshold           = 20
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT15M"
      }
    }
  }
}

# Create the Enrichment App Service
resource "azurerm_linux_web_app" "enrichmentapp" {
  name                                            = var.name
  location                                        = var.location
  resource_group_name                             = var.resourceGroupName
  service_plan_id                                 = azurerm_service_plan.appServicePlan.id
  https_only                                      = true
  tags                                            = var.tags
  webdeploy_publish_basic_authentication_enabled  = false
  client_affinity_enabled                         = false
  enabled                                         = true
  public_network_access_enabled                   = var.is_secure_mode ? false : true
  virtual_network_subnet_id                       = var.is_secure_mode ? var.subnetIntegration_id : null
  site_config {
    always_on                                     = var.alwaysOn
    app_command_line                              = var.appCommandLine
    ftps_state                                    = var.ftpsState
    health_check_path                             = var.healthCheckPath
    health_check_eviction_time_in_min             = 10
    http2_enabled                                 = true
    use_32_bit_worker                             = false
    worker_count                                  = 1

    application_stack {
      docker_image_name         = "${var.container_registry}/${var.container_name}:${data.local_file.image_tag.content}"
      docker_registry_url       = var.container_registry
      docker_registry_username  = var.container_registry_admin_username
      docker_registry_password  = var.container_registry_admin_password
    }
  }

  app_settings = merge(
    var.appSettings,
    {
      "SCM_DO_BUILD_DURING_DEPLOYMENT"            = lower(tostring(var.scmDoBuildDuringDeployment))
      "ENABLE_ORYX_BUILD"                         = tostring(var.enableOryxBuild)
      "APPLICATIONINSIGHTS_CONNECTION_STRING"     = var.applicationInsightsConnectionString
      "AZURE_SEARCH_SERVICE_KEY"                  = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/AZURE-SEARCH-SERVICE-KEY)"
      "COSMOSDB_KEY"                              = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/COSMOSDB-KEY)"
      "ENRICHMENT_KEY"                            = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/ENRICHMENT-KEY)"
      "AZURE_BLOB_STORAGE_KEY"                    = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/AZURE-BLOB-STORAGE-KEY)"
      "BLOB_CONNECTION_STRING"                    = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/BLOB-CONNECTION-STRING)"
      "AZURE_STORAGE_CONNECTION_STRING"           = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/BLOB-CONNECTION-STRING)"
      "AZURE_OPENAI_SERVICE_KEY"                  = "@Microsoft.KeyVault(SecretUri=${var.keyVaultUri}secrets/AZURE-OPENAI-SERVICE-KEY)"
      "KEY_EXPIRATION_DATE"                       = timeadd(timestamp(), "4320h") # Added expiration date setting for keys
    }
  )

  identity {
    type = var.managedIdentity ? "SystemAssigned" : null
  }
}

resource "azurerm_private_endpoint" "privateEnrichmentEndpoint" {
  count               = var.is_secure_mode ? 1 : 0
  name                = "${var.name}-private-endpoint"
  location            = var.location
  resource_group_name = var.resourceGroupName
  subnet_id           = var.subnet_id

  private_dns_zone_group {
    name = "privatednszonegroup"
    private_dns_zone_ids = var.private_dns_zone_ids
  }

  private_service_connection {
    name = "enrichementprivateendpointconnection"
    private_connection_resource_id = azurerm_linux_web_app.enrichmentapp.id
    subresource_names = ["sites"]
    is_manual_connection = false
  }
}

data "azurerm_key_vault" "existing" {
  name                = var.keyVaultName
  resource_group_name = var.resourceGroupName
}

resource "azurerm_key_vault_access_policy" "policy" {
  key_vault_id = data.azurerm_key_vault.existing.id

  tenant_id = azurerm_linux_web_app.enrichmentapp.identity.0.tenant_id
  object_id = azurerm_linux_web_app.enrichmentapp.identity.0.principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}