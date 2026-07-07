provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true # Set to false if you have a valid TLS cert on Proxmox
}

# --- ISO downloads ---

# Control plane ISO: always downloaded (control_planes map is never empty).
resource "proxmox_download_file" "talos_iso_controlplane" {
  node_name    = var.proxmox_node
  content_type = "iso"
  datastore_id = var.iso_datastore_id
  file_name    = "talos-cp-${var.control_plane_factory_hash}.iso"
  url          = "https://factory.talos.dev/image/${var.control_plane_factory_hash}/${var.talos_version}/metal-amd64.iso"
  overwrite    = false
}

# Worker ISO: only downloaded when workers map is non-empty and hash is set.
resource "proxmox_download_file" "talos_iso_worker" {
  count = length(var.workers) > 0 && var.worker_factory_hash != "" ? 1 : 0

  node_name    = var.proxmox_node
  content_type = "iso"
  datastore_id = var.iso_datastore_id
  file_name    = "talos-w-${var.worker_factory_hash}.iso"
  url          = "https://factory.talos.dev/image/${var.worker_factory_hash}/${var.talos_version}/metal-amd64.iso"
  overwrite    = false
}

# --- Control plane VMs ---

resource "proxmox_virtual_environment_vm" "control_plane" {
  for_each = var.control_planes

  name      = "talos-${each.key}"
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  description = "Talos control plane - grendel2 cluster. Node: ${each.key} IP: ${each.value.ip}"

  bios    = "ovmf"
  machine = "q35"

  # Boot from ISO on first boot; Talos writes bootloader to scsi0 on install.
  boot_order = ["ide2", "scsi0"]

  cdrom {
    file_id   = proxmox_download_file.talos_iso_controlplane.id
    interface = "ide2"
  }

  cpu {
    cores = var.control_plane_cpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.control_plane_memory
  }

  efi_disk {
    datastore_id = var.datastore_id
    file_format  = "raw"
    type         = "4m"
  }

  tpm_state {
    datastore_id = var.datastore_id
    version      = "v2.0"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.control_plane_disk
    file_format  = "raw"
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  vga {
    type = "std"
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.control_plane_factory_hash != ""
      error_message = "control_plane_factory_hash must be set."
    }
  }
}

# --- Worker VMs ---

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = var.workers

  name      = "talos-${each.key}"
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  description = "Talos worker - grendel2 cluster. Node: ${each.key} IP: ${each.value.ip}"

  bios    = "ovmf"
  machine = "q35"

  boot_order = ["ide2", "scsi0"]

  cdrom {
    file_id   = proxmox_download_file.talos_iso_worker[0].id
    interface = "ide2"
  }

  cpu {
    cores = var.worker_cpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.worker_memory
  }

  efi_disk {
    datastore_id = var.datastore_id
    file_format  = "raw"
    type         = "4m"
  }

  tpm_state {
    datastore_id = var.datastore_id
    version      = "v2.0"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.worker_disk
    file_format  = "raw"
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  vga {
    type = "std"
  }

  lifecycle {
    prevent_destroy = true

    # Guard: fail clearly if workers are declared but no hash provided.
    precondition {
      condition     = var.worker_factory_hash != ""
      error_message = "worker_factory_hash must be set when the workers map is non-empty."
    }
  }
}

# --- Talos machine config generation ---

provider "talos" {}

# Extract existing cluster secrets from the current machine config YAML.
locals {
  existing_config = yamldecode(file("${path.root}/../talos-infra/controlplane.yaml"))
}

data "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# --- Control plane machine configs ---

data "talos_machine_configuration" "control_plane" {
  for_each = var.control_planes

  cluster_name     = local.existing_config.cluster.clusterName
  cluster_endpoint = local.existing_config.cluster.controlPlane.endpoint
  machine_type     = "controlplane"
  talos_version    = var.talos_version
  machine_secrets  = data.talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = "talos-${each.key}"
          interfaces = [{
            interface = var.network_interface
            addresses = ["${each.value.ip}/${each.value.netmask}"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = each.value.gateway
            }]
          }]
        }
        install = {
          disk = "/dev/sda"
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
      }
    })
  ]
}

# --- Worker machine configs ---

data "talos_machine_configuration" "worker" {
  for_each = var.workers

  cluster_name     = local.existing_config.cluster.clusterName
  cluster_endpoint = local.existing_config.cluster.controlPlane.endpoint
  machine_type     = "worker"
  talos_version    = var.talos_version
  machine_secrets  = data.talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        network = {
          hostname = "talos-${each.key}"
          interfaces = [{
            interface = var.network_interface
            addresses = ["${each.value.ip}/${each.value.netmask}"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = each.value.gateway
            }]
          }]
        }
        install = {
          disk = "/dev/sda"
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
      }
    })
  ]
}

# --- Write generated configs to disk ---

resource "local_sensitive_file" "control_plane_config" {
  for_each = var.control_planes
  content  = data.talos_machine_configuration.control_plane[each.key].machine_config
  filename = "${path.root}/generated/talos-${each.key}.yaml"
}

resource "local_sensitive_file" "worker_config" {
  for_each = var.workers
  content  = data.talos_machine_configuration.worker[each.key].machine_config
  filename = "${path.root}/generated/talos-${each.key}.yaml"
}

# --- Apply machine configs to nodes (runs once per node, then user manages manually) ---

resource "null_resource" "apply_control_plane_config" {
  for_each = var.control_planes

  depends_on = [proxmox_virtual_environment_vm.control_plane]

  provisioner "local-exec" {
    command = "talosctl apply-config --insecure --nodes ${each.value.ip} --file ${path.root}/generated/talos-${each.key}.yaml"
  }
}

resource "null_resource" "apply_worker_config" {
  for_each = var.workers

  depends_on = [proxmox_virtual_environment_vm.worker]

  provisioner "local-exec" {
    command = "talosctl apply-config --insecure --nodes ${each.value.ip} --file ${path.root}/generated/talos-${each.key}.yaml"
  }
}