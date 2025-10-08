

# Cloud Connector Intall Extension
resource "azurerm_virtual_machine_extension" "cloud_connector" {
  name                 = "citrix-cloud-connector"
  virtual_machine_id   = var.vm_id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  auto_upgrade_minor_version = true

  settings = <<SETTINGS
    {
      "fileUris": [
        "https://az3557enstore.blob.core.windows.net/install/Citrix_Cloud_Connector/Cloud_cc_install.ps1?sp=r&st=2025-06-09T10:45:22Z&se=2025-06-16T18:45:22Z&spr=https&sv=2024-11-04&sr=b&sig=OmBh2QA6CiRW9mFdSYF53Uaa1iSQ2nFhWCjI6kCFDgw%3D"
      ],
      "commandToExecute": "powershell -ExecutionPolicy Unrestricted -File Cloud_cc_install.ps1"
    }
  SETTINGS

}

