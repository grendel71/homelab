provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true # Set to false if you have a valid TLS cert on Proxmox
}

resource "proxmox_virtual_environment_vm" "talos_controlplane" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  description = "Talos control plane node - grendel2 cluster. Image factory: ${var.talos_factory_hash}"

  # UEFI required for Talos secure boot / UKI
  bios = "ovmf"

  machine = "q35"

  # Boot order: network first so Talos PXE-installs on first boot.
  # After installation Talos rewrites the bootloader to disk; subsequent
  # reboots will boot from disk without PXE.
  boot_order = ["net0", "scsi0"]

  cpu {
    cores = 4
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 8192
  }

  # EFI disk required when bios = "ovmf"
  efi_disk {
    datastore_id = var.datastore_id
    file_format  = "raw"
    type         = "4m"
  }

  # TPM state disk (optional but recommended for Talos)
  tpm_state {
    datastore_id = var.datastore_id
    version      = "v2.0"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 100
    file_format  = "raw"
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    # mac_address is auto-assigned by Proxmox; Talos ignores it during PXE
  }

  # PXE boot is enabled via boot_order = ["net0", "scsi0"] above.
  # Your network DHCP/iPXE server must chainload:
  #   https://pxe.factory.talos.dev/pxe/3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5
  # See terraform.tfvars.example and plan docs for ISO fallback instructions.
  operating_system {
    type = "l26" # Linux 2.6+ kernel
  }

  # Cloud-init / serial console for visibility during boot
  serial_device {}

  vga {
    type = "serial0"
  }

  lifecycle {
    # Prevent accidental destruction of a running cluster node
    prevent_destroy = true
  }
}
