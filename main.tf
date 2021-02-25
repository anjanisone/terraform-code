terraform {
  required_version = ">= 0.12"
}

provider "azurerm" {
  version = "=2.8.0"
  features {}
}

resource "azurerm_resource_group" "dev-api-rg" {
  name     = var.vnet_resource_group_name
  location = var.location
}

module "bastion_network" {
  source              = "./modules/vnet"
  resource_group_name = azurerm_resource_group.dev-api-rg.name
  location            = var.location
  vnet_name           = var.bastion_vnet_name
  address_space       = ["10.0.4.0/22"]
  subnets = [
    {
      name : "AzureFirewallSubnet"
      address_prefixes : ["10.0.0.0/24"]
    },
    {
      name : "jumpbox-subnet"
      address_prefixes : ["10.0.1.0/24"]
    }
  ]
}

module "aks_network" {
  source              = "./modules/vnet"
  resource_group_name = azurerm_resource_group.dev-api-rg.name
  location            = var.location
  vnet_name           = var.aks_vnet_name
  address_space       = ["10.0.4.0/22"]
  subnets = [
    {
      name : "aks-subnet"
      address_prefixes : ["10.0.5.0/24"]
    }
  ]
}

module "vnet_peering" {
  source              = "./modules/vnet_peering"
  vnet_1_name         = var.bastion_vnet_name
  vnet_1_id           = module.bastion_network.vnet_id
  vnet_1_rg           = azurerm_resource_group.dev-api-rg.name
  vnet_2_name         = var.aks_vnet_name
  vnet_2_id           = module.aks_network.vnet_id
  vnet_2_rg           = azurerm_resource_group.dev-api-rg.name
  peering_name_1_to_2 = "BastiontoAKS"
  peering_name_2_to_1 = "AKStoBastion"
}

module "firewall" {
  source         = "./modules/firewall"
  resource_group = azurerm_resource_group.dev-api-rg.name
  location       = var.location
  pip_name       = "azureFirewalls-ip"
  fw_name        = "kubenetfw"
  subnet_id      = module.aks_network.subnet_ids["AzureFirewallSubnet"]
}

module "routetable" {
  source             = "./modules/route_table"
  resource_group     = azurerm_resource_group.dev-api-rg.name
  location           = var.location
  rt_name            = "kubenetfw_fw_rt"
  r_name             = "kubenetfw_fw_r"
  firewal_private_ip = module.firewall.fw_private_ip
  subnet_id          = module.bastion_network.subnet_ids["aks-subnet"]
}

module "storage_account" {
  source            = "./modules/storage_account"
  resource_group    = azurerm_resource_group.dev-api-rg.name
  location          = var.location
  sa_name           = "dev-api-storage_account"
}

backend "azurerm" {
  resource_group_name = azurerm_resource_group.dev-api-rg.name
  storage_account_name  = module.storage_account.name
  container_name        = module.storage_account.container_name
  key                   = "dev.terraform.state"
}

resource "azuread_application" "dev-api-application" {
  name                       = "dev-api-application"
  homepage                   = "http://homepage"
  identifier_uris            = ["http://uri"]
  reply_urls                 = ["http://replyurl"]
  available_to_other_tenants = false
  oauth2_allow_implicit_flow = true
}

resource "azuread_service_principal" "dev-api-service-pricipal" {
  application_id               = azuread_application.dev-api-application.application_id
  app_role_assignment_required = false

  tags = ["dev-api-application", "tags", "test-application-service-pricipal"]
}

resource "azurerm_kubernetes_cluster" "dev-api-aks" {
  name                    = "dev-api-aks"
  location                = var.location
  kubernetes_version      = var.kube_version
  resource_group_name     = azurerm_resource_group.dev-api-rg.name
  dns_prefix              = "dev-api-aks"
  private_cluster_enabled = true

  default_node_pool {
    name           = "default"
    node_count     = var.nodepool_nodes_count
    vm_size        = var.nodepool_vm_size
    vnet_subnet_id = module.bastion_network.subnet_ids["aks-subnet"]
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    docker_bridge_cidr = var.network_docker_bridge_cidr
    dns_service_ip     = var.network_dns_service_ip
    network_plugin     = "azure"
    outbound_type      = "userDefinedRouting"
    service_cidr       = var.network_service_cidr
  }

  depends_on = [module.routetable]
}

resource "azurerm_role_assignment" "netcontributor" {
  role_definition_name = "Network Contributor"
  scope                = module.bastion_network.subnet_ids["aks-subnet"]
  principal_id         = azurerm_kubernetes_cluster.privateaks.identity[0].principal_id
}

module "jumpbox" {
  source                  = "./modules/jumpbox"
  location                = var.location
  resource_group          = azurerm_resource_group.dev-api-rg.name
  vnet_id                 = module.aks_network.vnet_id
  subnet_id               = module.aks_network.subnet_ids["jumpbox-subnet"]
  dns_zone_name           = join(".", slice(split(".", azurerm_kubernetes_cluster.privateaks.private_fqdn), 1, length(split(".", azurerm_kubernetes_cluster.privateaks.private_fqdn))))
  dns_zone_resource_group = azurerm_kubernetes_cluster.privateaks.node_resource_group
}

resource "azurerm_network_interface" "bastion_nic" {
  name                = "dev-api-vm"
  location            = var.location
  resource_group_name = azurerm_resource_group.dev-api-rg.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = module.aks_network.subnet_ids["jumpbox-subnet"]
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "example" {
  name                            = "vm-bastion"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.dev-api-rg.name
  size                            = "Standard_D2_v2"
  admin_username                  = var.bastion_admin.username
  admin_password                  = var.bastion_admin.password
  disable_password_authentication = false
  network_interface_ids = [
    azurerm_network_interface.bastion_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
}

##
# Create an Azure Bastion Service to access the Bastion VM
##
resource "azurerm_public_ip" "pip_azure_bastion" {
  name                = "pip-azure-bastion"
  location            = var.location
  resource_group_name = azurerm_resource_group.dev-api-rg.name

  allocation_method = "Static"
  sku               = "Standard"
}

resource "azurerm_bastion_host" "azure-bastion" {
  name                = "azure-bastion"
  location            = var.location
  resource_group_name = azurerm_resource_group.dev-api-rg.name
  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion_network.id
    public_ip_address_id = azurerm_public_ip.pip_azure_bastion.id
  }
}
