resource "azurerm_resource_group" "main" {
  name     = "${var.project_name}-rg"
  location = var.location
}

### Virtual Network & Subnets

resource "azurerm_virtual_network" "main" {
  name                = "${var.project_name}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    Name = "${var.project_name}-vnet"
  }
}

# Public subnet — hosts the Application Gateway and NAT Gateway

resource "azurerm_subnet" "public" {
  count                = length(var.zones)
  name                 = "public-subnet-${count.index}-${var.project_name}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, count.index)]
}

# Private subnet — hosts the VM Scale Set instances

resource "azurerm_subnet" "private" {
  count = length(var.zones)

  name                 = "private-subnet-${count.index}-${var.project_name}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, count.index + length(var.zones))]
}

# Bastion subnet — name is fixed, Azure requires exactly "AzureBastionSubnet"
# Must be at least /26 (64 addresses) per Azure requirements
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 10)] # e.g. 10.0.10.0/24 — well clear of public/private ranges
}


resource "azurerm_public_ip" "nat" {
  count               = length(var.zones)
  name                = "${var.project_name}-nat-pip-${count.index + 1}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  zones               = [var.zones[count.index]] # Pin each EIP to its own zone

}

resource "azurerm_nat_gateway" "main" {
  count = length(var.zones)

  name                = "${var.project_name}-nat-gateway-${count.index + 1}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
  zones               = [var.zones[count.index]] # Pin each NAT Gateway to its own zone
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count = length(var.zones)

  nat_gateway_id       = azurerm_nat_gateway.main[count.index].id
  public_ip_address_id = azurerm_public_ip.nat[count.index].id
}

# Each private subnet gets its own NAT Gateway — traffic stays within the same zone
resource "azurerm_subnet_nat_gateway_association" "private" {
  count = length(var.zones)

  subnet_id      = azurerm_subnet.private[count.index].id
  nat_gateway_id = azurerm_nat_gateway.main[count.index].id
}

# NSG for the Application Gateway subnet — allow HTTP from internet
resource "azurerm_network_security_group" "appgw" {
  name                = "${var.project_name}-appgw-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-http-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Required rule for Application Gateway health probes and management traffic
  security_rule {
    name                       = "allow-appgw-management"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }
}

# NSG for the private (app) subnet — only allow traffic from App Gateway subnet
resource "azurerm_network_security_group" "app" {
  name                = "${var.project_name}-app-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-appgw-to-app"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefixes    = [for s in azurerm_subnet.public : s.address_prefixes[0]]
    destination_address_prefix = "*"
  }

  # Allow Bastion to reach VMs on SSH (22) — source is the AzureBastionSubnet CIDR only
  # This means only traffic coming from Bastion can use port 22, not the open internet
  security_rule {
    name                       = "allow-bastion-to-vms"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22"]
    source_address_prefix      = azurerm_subnet.bastion.address_prefixes[0]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
# NSGs subnet associations — each subnet gets its own NSG association, one for the App Gateway and one for the private app subnet
resource "azurerm_subnet_network_security_group_association" "appgw" {
  count = length(var.zones)

  subnet_id                 = azurerm_subnet.public[count.index].id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  count = length(var.zones)

  subnet_id                 = azurerm_subnet.private[count.index].id
  network_security_group_id = azurerm_network_security_group.app.id
}

### Application Gateway (Azure equivalent of ALB)

resource "azurerm_public_ip" "appgw" {
  name                = "${var.project_name}-appgw-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones

  tags = {
    Name = "${var.project_name}-appgw-pip"
  }
}

locals {
  appgw_backend_pool_name  = "${var.project_name}-backend-pool"
  appgw_frontend_port_name = "${var.project_name}-frontend-port"
  appgw_frontend_ip_name   = "${var.project_name}-frontend-ip"
  appgw_http_setting_name  = "${var.project_name}-http-setting"
  appgw_listener_name      = "${var.project_name}-http-listener"
  appgw_rule_name          = "${var.project_name}-routing-rule"
  appgw_probe_name         = "${var.project_name}-health-probe"
}

resource "azurerm_application_gateway" "main" {
  name                = "${var.project_name}-appgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  zones               = var.zones

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2 # Static capacity; use autoscale_configuration block for dynamic scaling
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.public[0].id
  }

  frontend_ip_configuration {
    name                 = local.appgw_frontend_ip_name
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = local.appgw_frontend_port_name
    port = 80
  }

  backend_address_pool {
    name = local.appgw_backend_pool_name
  }

  backend_http_settings {
    name                  = local.appgw_http_setting_name
    cookie_based_affinity = "Disabled"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 60

    probe_name = local.appgw_probe_name
  }

  probe {
    name                = local.appgw_probe_name
    host                = "127.0.0.1"
    protocol            = "Http"
    path                = "/"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
  }

  http_listener {
    name                           = local.appgw_listener_name
    frontend_ip_configuration_name = local.appgw_frontend_ip_name
    frontend_port_name             = local.appgw_frontend_port_name
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = local.appgw_rule_name
    rule_type                  = "Basic"
    http_listener_name         = local.appgw_listener_name
    backend_address_pool_name  = local.appgw_backend_pool_name
    backend_http_settings_name = local.appgw_http_setting_name
    priority                   = 100
  }

  tags = {
    Name = "${var.project_name}-appgw"
  }
}

### Azure Bastion (replaces SSH access — connect to private VMs via Azure Portal over HTTPS) This is a secure way to access VMs in private subnets without exposing SSH ports to the internet. 
## However, it does require a dedicated subnet (AzureBastionSubnet) and a public IP address. Bastion is a managed service, so you don't have to worry about patching or maintaining it.
## It needs a public IP and there is a limit to the number of Public IPs you can have in a subscription, so plan accordingly. Bastion is also not free, so check the pricing before deploying it.So 
## we would be greying out the bastion host and public IP 

/** resource "azurerm_public_ip" "bastion" {
  name                = "${var.project_name}-bastion-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    Name = "${var.project_name}-bastion-pip"
  }
}

resource "azurerm_bastion_host" "main" {
  name                = "${var.project_name}-bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }

  tags = {
    Name = "${var.project_name}-bastion"
  }
}
**/

### User-Assigned Managed Identity (equivalent of EC2 IAM role)

resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.project_name}-vmss-identity"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

### VM Scale Set (equivalent of ASG + Launch Template)

data "azurerm_platform_image" "main" {
  location  = var.location
  publisher = "Canonical"
  offer     = "0001-com-ubuntu-server-jammy"
  sku       = "22_04-lts-gen2"
}

resource "azurerm_linux_virtual_machine_scale_set" "app" {
  name                = "${var.project_name}-vmss"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard_D2ds_v7"
  instances           = 2            # Desired capacity
  zones               = var.zones

  upgrade_mode = "Manual"



  admin_username                  = "azureuser"
  disable_password_authentication = false # Set to FAlse because we are not using SSH keys, but rather Azure Bastion for access.
  admin_password                  = var.admin_password
  # No SSH key — access is via Azure Bastion through the portal (HTTPS/443)
  # Bastion authenticates using your Azure AD credentials; port 22 is never opened

  source_image_reference {
    publisher = data.azurerm_platform_image.main.publisher
    offer     = data.azurerm_platform_image.main.offer
    sku       = data.azurerm_platform_image.main.sku
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  network_interface {
    name    = "${var.project_name}-vmss-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.private[0].id
      application_gateway_backend_address_pool_ids = [
        for pool in azurerm_application_gateway.main.backend_address_pool :
        pool.id if pool.name == local.appgw_backend_pool_name
      ]
    }
  }

}