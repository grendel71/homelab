output "control_plane_vm_ids" {
  description = "Map of control plane node key to Proxmox VM ID"
  value       = { for k, v in proxmox_virtual_environment_vm.control_plane : k => v.vm_id }
}

output "worker_vm_ids" {
  description = "Map of worker node key to Proxmox VM ID"
  value       = { for k, v in proxmox_virtual_environment_vm.worker : k => v.vm_id }
}

output "post_provision_steps" {
  description = "Manual steps required after terraform apply to join all nodes to the cluster"
  value = <<-EOT
    Next steps to join nodes to grendel2 cluster:

    1. Wait for each VM to complete ISO boot and Talos installation (~2-5 min each).
       Monitor in Proxmox console per VM.

    2. Apply control plane machine config for each control plane node (from repo root):
    %{for k, v in var.control_planes~}
       talosctl apply-config --insecure --nodes ${v.ip} --file talos-infra/controlplane.yaml
    %{endfor~}

    3. Apply worker machine config for each worker node (from repo root):
    %{for k, v in var.workers~}
       talosctl apply-config --insecure --nodes ${v.ip} --file talos-infra/worker.yaml
    %{endfor~}

    4. Verify all nodes join the cluster:
       kubectl get nodes -o wide

    Note: Node IPs are set in talos-infra/ machine configs, not managed by Terraform.
  EOT
}