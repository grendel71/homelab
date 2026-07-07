provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true # Set to false if you have a valid TLS cert on Proxmox
}

# Download the Talos factory ISO into Proxmox storage.
# Proxmox fetches it directly from the factory — no manual upload needed.
# Re-running terraform apply will not re-download if the file already exists.
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  node_name    = var.proxmox_node
  content_type = "iso"
  datastore_id = var.iso_datastore_id
  file_name    = "talos-${var.talos_factory_hash}.iso"
  url          = "https://factory.talos.dev/image/${var.talos_factory_hash}/${var.talos_version}/metal-amd64.iso"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "talos_controlplane" {
  name      = var.vm_name
  node_name = var.proxmox_node
  vm_id     = var.vm_id

  description = "Talos control plane node - grendel2 cluster. Image factory: ${var.talos_factory_hash}"

  # UEFI required for Talos secure boot / UKI
  bios = "ovmf"

  machine = "q35"

  # Boot from ISO on first boot; Talos installer writes bootloader to scsi0.
  # Subsequent reboots go straight to disk — the CDROM is ignored once installed.
  boot_order = ["ide2", "scsi0"]

  # Talos factory ISO attached as CDROM on ide2.
  # q35 supports ide0 and ide2 only; ide2 is the conventional CDROM slot.
  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso.id
    interface = "ide2"
  }

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
    discard      = "on"      # enables TRIM/discard passthrough (valid values: "on", "ignore")
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    # mac_address is auto-assigned by Proxmox; Talos ignores it during PXE
  }

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
