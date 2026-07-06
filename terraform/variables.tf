variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL (include trailing slash)"
  type        = string
  default     = "https://192.168.1.171:8006/"
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID, e.g. terraform@pam!tf"
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

variable "vm_name" {
  description = "VM name as shown in Proxmox"
  type        = string
  default     = "talos-cp-03"
}

variable "vm_id" {
  description = "Proxmox VM ID (must be unique in the cluster)"
  type        = number
  default     = 300
}

variable "datastore_id" {
  description = "Proxmox storage pool for the VM disk (e.g. local-lvm, local)"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Proxmox network bridge for the VM NIC"
  type        = string
  default     = "vmbr0"
}

variable "talos_factory_hash" {
  description = "Talos image factory schematic hash for the custom image"
  type        = string
  default     = "3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5"
}
