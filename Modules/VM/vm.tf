
# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Get existing subnet
data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.pl_resource_group_name
}

# Get existing NSG
data "azurerm_network_security_group" "nsg" {
  name                = var.nsg_name
  resource_group_name = var.pl_resource_group_name
}

# NIC
resource "azurerm_network_interface" "nic" {
  name                = "${var.vm_name}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }

  #network_security_group_id = data.azurerm_network_security_group.nsg.id
}

# VM
resource "azurerm_windows_virtual_machine" "vm" {
  name                = var.vm_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]
  provision_vm_agent = true
  license_type       = "Windows_Server"

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    name                 = "${var.vm_name}-osdisk"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }
}
  # Domain Join Extension
resource "azurerm_virtual_machine_extension" "domain_join_custom" {
  name                       = "domainjoin-custom"
  virtual_machine_id         = azurerm_windows_virtual_machine.vm.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  settings = <<SETTINGS
{
  "fileUris": [
    "https://az3557enstore.blob.core.windows.net/install/Join-Domain.ps1?sp=r&st=2025-06-06T07:10:36Z&se=2025-06-06T15:10:36Z&spr=https&sv=2024-11-04&sr=b&sig=0UcFO1lMys%2BLe5dPJ9r%2BxH%2FM5rwFBNVrrEyNSwYo8f8%3D"
  ],
  "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File Join-Domain.ps1"
}
SETTINGS

  
 depends_on = [azurerm_virtual_machine_extension.cloud_connector.name]
}




