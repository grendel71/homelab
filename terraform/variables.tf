variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL (include trailing slash, e.g. https://192.168.1.171:8006/)"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID, e.g. root@pam!tf"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret UUID"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Name of the Proxmox node (visible in Proxmox UI under Datacenter)"
  type        = string
  default     = "pve"
}

variable "datastore_id" {
  description = "Proxmox storage pool for VM disks (must support disk images, e.g. local-lvm)"
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore_id" {
  description = "Proxmox storage pool for ISO downloads (must support iso content, e.g. local)"
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox network bridge for all VM NICs"
  type        = string
  default     = "vmbr0"
}

variable "network_interface" {
  description = "Network interface name for Talos static IP configuration (e.g. eth0)"
  type        = string
  default     = "eth0"
}

variable "talos_version" {
  description = "Talos version for all nodes, used to construct factory ISO URLs (e.g. v1.13.0)"
  type        = string
  default     = "v1.13.0"
}

# --- Control plane nodes ---

variable "control_planes" {
  description = "Map of control plane nodes. Key becomes the VM name suffix (e.g. 'cp-03' → 'talos-cp-03'). ip is informational only (set in talos-infra/controlplane.yaml)."
  type = map(object({
    ip      = string
    vm_id   = number
    gateway = optional(string, "192.168.1.1")
    netmask = optional(number, 24)
  }))
  default = {
    cp-03 = { ip = "192.168.1.103", vm_id = 300 }
  }
}

variable "control_plane_cpu" {
  description = "Number of vCPU cores for each control plane node"
  type        = number
  default     = 4
}

variable "control_plane_memory" {
  description = "RAM in MB for each control plane node"
  type        = number
  default     = 8192
}

variable "control_plane_disk" {
  description = "Disk size in GB for each control plane node"
  type        = number
  default     = 100
}

variable "control_plane_factory_hash" {
  description = "Talos image factory schematic hash for control plane nodes. Default hash corresponds to the grendel2 cluster schematic — regenerate at factory.talos.dev if changing extensions."
  type        = string
  default     = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
}

# --- Worker nodes ---

variable "workers" {
  description = "Map of worker nodes. Key becomes the VM name suffix (e.g. 'w-01' → 'talos-w-01'). ip is informational only (set in talos-infra/worker.yaml)."
  type = map(object({
    ip      = string
    vm_id   = number
    gateway = optional(string, "192.168.1.1")
    netmask = optional(number, 24)
  }))
  default = {}
}

variable "worker_cpu" {
  description = "Number of vCPU cores for each worker node"
  type        = number
  default     = 4
}

variable "worker_memory" {
  description = "RAM in MB for each worker node"
  type        = number
  default     = 8192
}

variable "worker_disk" {
  description = "Disk size in GB for each worker node"
  type        = number
  default     = 100
}

variable "worker_factory_hash" {
  description = "Talos image factory schematic hash for worker nodes. Required when workers map is non-empty — enforced via precondition on the worker VM resource."
  type        = string
  default     = ""
}
