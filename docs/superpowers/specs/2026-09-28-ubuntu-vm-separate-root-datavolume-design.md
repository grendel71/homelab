# Ubuntu VM separate root DataVolume

## Purpose

Give the Ubuntu VM one persistent root disk managed independently from the
VirtualMachine resource.

## Design

Create a `cdi.kubevirt.io/v1beta1` `DataVolume` named
`ubuntu-vm-rootdisk` in namespace `kubevirt`. Its registry source imports
`docker://quay.io/containerdisks/ubuntu:24.04` into a 20Gi,
ReadWriteOnce Rook Ceph PVC using `replicated-x3-block-store`.

The VirtualMachine will remove its inline `dataVolumeTemplates` block and
reference the separate DataVolume from its `rootdisk` volume. The manifest
will remove the unused `ubuntu-vm-data` PVC and `datadisk`. Cloud-init and
the SSH LoadBalancer Service remain unchanged.

## Validation

Render the Kustomization. Confirm one DataVolume, one VirtualMachine, and one
SSH Service. Confirm the DataVolume uses the selected image, StorageClass, and
20Gi storage request, and the VM rootdisk references `ubuntu-vm-rootdisk`.
