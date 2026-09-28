# Ubuntu VM cloud-init and Ceph PVC

## Purpose

Configure the KubeVirt Ubuntu test VM with a login user and persistent data storage.

## Design

The `kubevirt` namespace will contain a `PersistentVolumeClaim` named
`ubuntu-vm-data`. It will request 10Gi of filesystem storage through the
`replicated-x3-block-store` Rook Ceph StorageClass. The VM will attach this
claim as a virtio data disk.

The VM will add a `cloudInitNoCloud` config disk. Its user data will create
user `blau`, give this user sudo access, and add the public key from
`~/.ssh/intranet.pub` to the user's authorized SSH keys.

The existing Ubuntu container disk remains the root disk. The new PVC is a
separate data disk and does not make the root disk persistent.

## Validation

Build the VM kustomization with Kustomize. Confirm that the result includes
one valid VirtualMachine and one PVC with the selected StorageClass, requested
size, cloud-init volume, and attached data disk.
