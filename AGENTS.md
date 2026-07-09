# Talos homelab — FluxCD-managed Kubernetes cluster on Proxmox

## Dev environment

**ALL Kubernetes/Talos commands require the Nix dev shell.** The flake provides `talosctl`, `kubectl`, `sops`, `age`, `flux`, `terraform`, and `velero` — none of these are available outside the shell.

```bash
direnv allow   # activates the flake automatically on cd into repo
# or: nix develop
```

The flake shellHook decrypts SOPS secrets and sets `KUBECONFIG`/`TALOSCONFIG` to in-repo dev files (`.gitignore`d). You must have `age.agekey` present (also `.gitignore`d). Without the shell, `kubectl` and `talosctl` will have no config and all commands will fail.

## Project layout

| Directory | Purpose |
|---|---|
| `talos-infra/` | **Source of truth** for Talos machine configs (controlplane + worker YAMLs). Do NOT edit the generated configs under `terraform/generated/`. |
| `terraform/` | Proxmox VM provisioning + machine config generation + `talosctl apply-config`. Requires `terraform.tfvars` (secrets: Proxmox API token). |
| `k8s/` | FluxCD-managed cluster resources. Synced from `github.com/grendel71/homelab` branch `main`, path `./k8s`. |
| `secrets/` | SOPS-encrypted `kubeconfig` and `talosconfig` (decrypted by shellHook into repo root). |
| `scripts/` | Operational helpers (sourced or one-shot). Not part of the Flux pipeline. |

## Terraform workflow

```bash
cd terraform
# terraform.tfvars is required (copy from .example, fill in Proxmox API secrets)
terraform init
terraform plan
terraform apply
```

Terraform reads `../talos-infra/controlplane.yaml` and `../talos-infra/worker.yaml` as base configs, merges per-node hostname/IP/network/install overrides, writes generated files to `terraform/generated/`, then pushes them to nodes via `talosctl apply-config --insecure`.

**Critical:** VM resources have `prevent_destroy = true`. Worker VMs require `worker_factory_hash` to be set in tfvars if the workers map is non-empty.

## Talos versions and images

- Control plane: Talos `v1.12.6` (stock installer)
- Workers: Talos `v1.13.0` (stock or factory images for NVIDIA/cloud-init)
- Factory image hashes are set in terraform vars; regenerate at [factory.talos.dev](https://factory.talos.dev) if changing system extensions.
- NVIDIA workers need **both** a factory image (NVIDIA drivers baked in) **and** a patch (`talos-infra/gpu-worker-patch.yaml`) that loads kernel modules (`nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`).
- `talosctl patch` is used to apply per-node overrides (etcd subnet, nodeIP — see `talos-infra/patch-*.yaml`).

## FluxCD architecture

Flux bootstraps from `k8s/kustomization.yaml` → `flux-system/` + `flux/kustomizations/`. Secrets are decrypted via the `sops-age` secret in `flux-system` namespace.

**Kustomizations follow a strict dependency order** (defined by `dependsOn` in each `Kustomization` resource):

1. `sources` → `namespaces` → `infra-secrets` → `crds`
2. `infra-releases` → `ceph-cluster` → `object-store` → `storage`
3. `cert-manager` → `cert-manager-issuers` → `cnpg` → `metallb` → `metallb-config`
4. `kube-vip` → `envoy-gateway` → `envoy-gateway-config` → `traefik-internal`
5. `ingress` → `external-dns-cloudflare` → `cloudflared`
6. `arc` → `nvidia-operator` → `velero`
7. **Apps** then depend on `cnpg`, `storage`, `cert-manager` etc.

## Secrets management

- **SOPS + age** for all encryption (`.sops.yaml` at repo root).
- Flux decrypts at apply time via the `sops-age` secret in `flux-system`.
- To edit a secret: `sops <file>` (SOPS auto-detects from `.sops.yaml` rules).
- To create the Flux decryption secret: `scripts/sops-age-secret.sh`.
- GitHub credentials for Flux: `scripts/create_flux_gh.sh` (needs `$GITHUB_USER`/`$GITHUB_TOKEN`).

## Networking

- **kube-vip** VIP: `192.168.1.100` (control plane API endpoint). All node configs explicitly exclude this from kubelet `nodeIP` and etcd `advertisedSubnets`.
- **Metallb** LB pool: `192.168.1.69` (Envoy Gateway external) and `192.168.1.70` (Envoy Gateway internal).
- **Dual gateway**: Envoy Gateway handles external HTTPS (TLS via cert-manager + Cloudflare DNS challenge). Traefik handles internal-only ingress.
- **external-dns** syncs HTTPRoute hostnames to Cloudflare DNS (proxied).
- **cloudflared** provides Cloudflare Tunnel without port forwarding.

## Storage

- **Rook Ceph** provides distributed block storage (`ceph-block` StorageClass, RWO) and S3-compatible object store (`s3.envoy.grendel71.net`).
- Static NFS/CSI PVs for media, Nextcloud, Immich volumes.
- `scripts/rook-password.sh` retrieves the Ceph dashboard password.
- `scripts/s3-env.sh` exports S3 credentials (source it, then use `aws s3 --endpoint-url $S3_ENDPOINT`).

## Database

- **CloudNativePG** runs PostgreSQL clusters for stateful apps (Authentik, Immich, Nextcloud, Pappwiki).
- Each app gets its own CNPG cluster resource in the app's namespace.

## Common gotchas

- Synthetic `kustomization.yaml` files (e.g., in `k8s/flux/kustomizations/`, `k8s/infra/`, `k8s/apps/*/`) are Flux's entrypoints — they point into subdirectories. Editing manifests inside a directory won't take effect if the parent kustomization doesn't include it.
- `internal` vs `external` Gateway classes are meaningful: apps choose one or both via HTTPRoute `parentRefs`.
- GPU workloads (Open WebUI) need the NVIDIA GPU operator deployed (via `infra/nvidia/` kustomization) and nodes that have the NVIDIA factory image + kernel module patch.
- The `talos-infra/` configs use the cluster name `grendel2`. Changing this requires regenerating all machine configs.
