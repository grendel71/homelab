output "vm_id" {
  description = "Proxmox VM ID of the provisioned control plane node"
  value       = proxmox_virtual_environment_vm.talos_controlplane.vm_id
}

output "vm_name" {
  description = "VM name in Proxmox"
  value       = proxmox_virtual_environment_vm.talos_controlplane.name
}

output "post_provision_steps" {
  description = "Manual steps required after terraform apply"
  value       = <<-EOT
    Next steps to join node to grendel2 cluster:

    1. Wait for the VM to complete PXE boot and Talos installation (~2-5 min).
       Monitor in Proxmox console: VM ${proxmox_virtual_environment_vm.talos_controlplane.vm_id} > Console

    2. Apply the control plane machine config (from repo root):
       talosctl apply-config --insecure \
         --nodes ${var.vm_ip} \
         --file talos-infra/controlplane.yaml

    3. Verify the node joins the cluster:
       kubectl get nodes -o wide

    Note: Node IP ${var.vm_ip} is set in talos-infra/controlplane.yaml,
    not managed by Terraform.
  EOT
}
