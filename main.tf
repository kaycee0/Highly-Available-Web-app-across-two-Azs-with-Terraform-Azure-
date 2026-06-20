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
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 10)]  # e.g. 10.0.10.0/24 — well clear of public/private ranges
}


resource "azurerm_public_ip" "nat" {
    count = length(var.zones)
  name                = "${var.project_name}-nat-pip-${count.index + 1}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  zones               = [var.zones[count.index]]  # Pin each EIP to its own zone

}

resource "azurerm_nat_gateway" "main" {
  count = length(var.zones)

  name                = "${var.project_name}-nat-gateway-${count.index + 1}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
  zones               = [var.zones[count.index]]  # Pin each NAT Gateway to its own zone
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
    source_address_prefix      = cidrsubnet(var.vnet_cidr, 8, 10)  # AzureBastionSubnet — must match azurerm_subnet.bastion
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
NSGs subnet associations — each subnet gets its own NSG association, one for the App Gateway and one for the private app subnet
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