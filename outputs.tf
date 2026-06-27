output "appgw_public_ip" {
  description = "Public IP address of the Application Gateway"
  value       = azurerm_public_ip.appgw.ip_address
}

/** output "bastion_public_ip" {
  description = "Public IP address of the Bastion host (access via Azure Portal, not directly)"
  value       = azurerm_public_ip.bastion.ip_address
}
**/

output "vmss_id" {
  description = "ID of the VM Scale Set"
  value       = azurerm_linux_virtual_machine_scale_set.app.id
}
