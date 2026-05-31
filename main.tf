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