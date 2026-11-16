# Talos homelab — FluxCD-managed Kubernetes cluster on Proxmox

Cluster name: `grendel2`. Kubernetes `v1.35.2`.

## Dev environment

**ALL Kubernetes/Talos commands require the Nix dev shell.** The flake provides `talosctl`, `kubectl` (with krew plugins `rook-ceph`, `ktop`, `ns`, `modify-secret`, `open-svc`), `sops`, `age`, `ssh-to-age`, `flux`, `velero`, `kubevirt`, `virt-viewer` and `google-cloud-sdk`. None of these are available outside the shell.

```bash
direnv allow   # activates the flake automatically on cd into repo
# or: nix develop
# one-shot:  nix develop --command bash -c 'kubectl get nodes'
```

The flake shellHook decrypts SOPS secrets and sets `KUBECONFIG=.kubeconfig.dev` and `TALOSCONFIG=.talosconfig.dev` (both `.gitignore`d). You need `age.agekey` present (also `.gitignore`d). Without the shell, `kubectl` and `talosctl` have no config and all commands fail.

The shellHook also sets the Talos API endpoint and the default node list from `CONTROL_PLANE_IPS`, `CONTROL_PLANE_NODE_IPS` and `WORKER_IPS` in `flake.nix`. **Update these variables when you add or remove a node.** A stale IP makes `talosctl health` fail.

## Cluster nodes

| Node | Role | IP |
|---|---|---|
| talos-1i8-qm9 | control-plane | 192.168.1.145 |
| talos-47z-ayo | control-plane | 192.168.1.176 |
| talos-cp-03 | control-plane | 192.168.1.154 |
| talos-hjl-umn | worker | 192.168.1.103 |
| talos-i4x-2pd | worker | 192.168.1.215 |
| talos-uxk-0na | worker | 192.168.1.144 |
| talos-xyn-p5v | worker | 192.168.1.233 |

Verify with `kubectl get nodes -o wide`. This table can go stale.

## Project layout

| Path | Purpose |
|---|---|
| `k8s/` | FluxCD-managed cluster resources. Synced from `github.com/grendel71/homelab`, branch `main`, path `./k8s`. |
| `k8s/flux-system/` | Flux bootstrap (`gotk-components.yaml`, `gotk-sync.yaml`). |
| `k8s/infrastructure/<name>/` | One folder per infra component: `ks.yaml` (Flux `Kustomization`) + `app/` (manifests). |
| `k8s/apps/<name>/` | One folder per app, same `ks.yaml` + `app/` pattern. |
| `k8s/common/all-namespaces/` | Resources shared by all namespaces (e.g. `app-template` OCI repo). |
| `secrets/` | SOPS-encrypted `kubeconfig` and `talosconfig` (decrypted by the shellHook). |
| `scripts/` | Operational helpers. Not part of the Flux pipeline. |
| `docs/superpowers/` | Design specs and plans. Git-ignored. |
| `talos-infra/` | **Local only, git-ignored.** Talos machine configs (`controlplane.yaml`, `worker.yaml`, `workernvme.yaml`, `workernvidia.yaml`, `controllaptop.yaml`, `controlmaster.yaml`) and `patch-*.yaml` files. Some patch files are for nodes that no longer exist. |
| `patches/` | **Local only, git-ignored.** Small ad-hoc Talos patches. |
| `.worktrees/` | Git-ignored worktrees. Ignore them when you search. |

Terraform was removed (commit `e8c54a6`). Nodes are no longer provisioned from this repo. Create VMs in Proxmox by hand, then apply Talos configs with `talosctl`.

## Talos versions and images

- Control plane: mixed. `talos-1i8-qm9` runs `v1.12.6`; the other two run `v1.13.0`.
- Workers: mostly `v1.13.0`; `talos-i4x-2pd` runs `v1.12.6`.
- Check the current versions with `kubectl get nodes -o wide`.
- Factory images (system extensions, such as NVIDIA or cloud-init) come from [factory.talos.dev](https://factory.talos.dev). Regenerate the hash if you change the extensions.
- NVIDIA workers need **both** a factory image (NVIDIA drivers) **and** `talos-infra/gpu-worker-patch.yaml`, which loads the kernel modules (`nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`).
- Per-node overrides (etcd subnet, `nodeIP`) are applied with `talosctl apply-config --patch @file` or `talosctl patch mc`.
- Changing the cluster name requires regenerating all machine configs.

## FluxCD architecture

Flux starts from `k8s/kustomization.yaml`, which includes `flux-system`, `infrastructure` and `apps`. Each component has a `ks.yaml` with `dependsOn`. Secrets are decrypted with the `sops-age` secret in the `flux-system` namespace.

Main infrastructure dependencies (see each `ks.yaml` for the full list):

- `sources` → `crds`, `infra-secrets` → `infra-releases` → `arc`, `ceph-cluster`
- `ceph-cluster` → `object-store`, `storage`
- `cert-manager` → `cert-manager-issuers`; `cert-manager` + `metallb` + `crds` → `envoy-gateway` → `cloudflared`, `external-dns-cloudflare`
- `traefik-internal` + `envoy-gateway` → `ingress`
- `metallb` → `metallb-config`; `kube-vip`, `cnpg`, `nvidia-operator`, `velero`, `kubevirt` are standalone or depend only on `namespace`/`infra-secrets`.
- `namespace` + `infra-secrets` → `etcd-backup`

Check state with `flux get kustomizations` and `flux get helmreleases -A`.

## Secrets management

- **SOPS + age** for all encryption (`.sops.yaml` at repo root).
- To edit a secret: `sops <file>`.
- To create the Flux decryption secret: `scripts/sops-age-secret.sh`.
- GitHub credentials for Flux: `scripts/create_flux_gh.sh` (needs `$GITHUB_USER` and `$GITHUB_TOKEN`).
- Never commit `.env`, `age.agekey`, `etcd-*.db` or the decrypted `.kubeconfig.dev` / `.talosconfig.dev`.

## Networking

- **kube-vip** VIP `192.168.1.100` is the control plane API endpoint. Node configs exclude it from kubelet `nodeIP` (`'!192.168.1.100/32'`) and from etcd `advertisedSubnets`.
- **Metallb** pool: `192.168.1.69` (Envoy Gateway external) and `192.168.1.70` (Envoy Gateway internal).
- **Dual gateway**: Envoy Gateway handles external HTTPS (TLS via cert-manager + Cloudflare DNS challenge). Traefik handles internal-only ingress. Apps choose `internal`, `external` or both with HTTPRoute `parentRefs`.
- **external-dns** syncs HTTPRoute hostnames to Cloudflare DNS.
- **cloudflared** provides a Cloudflare Tunnel without port forwarding.

## Storage

- **Rook Ceph** (`useAllNodes`/`useAllDevices`): `ceph-block` StorageClass (RWO) and an S3 object store (`s3.envoy.grendel71.net`). OSDs run on the workers.
- Static NFS/CSI PVs for media, Nextcloud and Immich volumes.
- Ceph commands: `kubectl rook-ceph ceph status`, `kubectl rook-ceph ceph osd tree`.
- `scripts/rook-password.sh` gets the Ceph dashboard password.
- `scripts/s3-env.sh` exports S3 credentials for the **Ceph** object store only (source it, then use `aws s3 --endpoint-url $S3_ENDPOINT`). It does not work for the backup bucket. See [Backups](#backups).

## Database

- **CloudNativePG** runs PostgreSQL clusters for stateful apps. Each app has its own CNPG cluster in the app namespace.

## Backups

Two automated backups run. Both write to the **same S3 bucket**, `velero`, on **SeaweedFS** at `http://192.168.1.231:30304`. This is **not** the Ceph object store. The Ceph admin keys and `scripts/s3-env.sh` do not work there. SeaweedFS has its own users. The backup storage host has the same IP as the NFS server. The backups are not off-site.

| Backup | What it covers | Schedule | Bucket path | Retention |
|---|---|---|---|---|
| Velero `apps-daily` | Kubernetes objects and Ceph volume data of opted-in namespaces | Daily 02:00 `America/New_York` | `backups/` (metadata), `kopia/` (volume data) | 7 days (`ttl: 168h`) |
| `etcd-snapshot` CronJob | etcd database | Every 6 hours at `:15` `America/New_York` | `etcd/etcd-<UTC timestamp>.snapshot` | 7 days (script deletes older objects) |

### Velero

- Files: `k8s/infrastructure/velero/` (`app/release.yaml`, `app/resource-policies.yaml`, `app/schedule.yaml`).
- Velero is installed in `kube-system`, **not** `velero`. Always pass `-n kube-system` to the `velero` CLI.
- Running `v1.19.0-rc.1` (prerelease) on Helm chart `12.2.5`, with `velero-plugin-for-aws:v1.15.0-rc.1`. The dev shell CLI is `v1.18.x`. It works but prints a version warning.
- **Opt in a namespace** with the label `backup.grendel71.net/enabled: "true"` on its `Namespace` object (`k8s/infrastructure/namespaces/app/<name>.yaml`). The resource policy selects namespaces by this label. This needs Velero 1.19. Do not roll back to 1.18 while the policy ConfigMap exists. 1.18 ignores the label rule and could back up all namespaces.
- Opted-in now: `ai`, `apps`, `authentik`, `immich`, `leaderboard`, `lifter`, `litellm`, `nextcloud-new`, `pappwiki`, `torrent`, `vaultwarden`. `payments` is not labeled. Its namespace comes from the external `payment-processor` repo.
- **NFS volume data is skipped** by a `volumePolicies` rule (`nfs: {}` → `skip`). The PVC and PV objects are still backed up. The NFS data must be backed up on the NAS.
- The policy ConfigMap `velero-resource-policies` must stay in `kube-system` and must have **exactly one** data key.
- Volume data uses file-system backup (`defaultVolumesToFsBackup: true`, Kopia). It only backs up volumes of **running** pods.
- `kubectl get backup` resolves to the CNPG CRD. Use `kubectl get backups.velero.io`.

```bash
velero schedule get -n kube-system
velero backup get -n kube-system
velero backup create --from-schedule apps-daily -n kube-system     # run one now
velero backup describe <name> -n kube-system --details
velero backup logs <name> -n kube-system | grep "Summary for skipped volumes"
```

### etcd snapshots

- Files: `k8s/infrastructure/etcd-backup/` (`ks.yaml`, `app/cronjob.yaml`). Namespace `backup`.
- The CronJob runs on a control-plane node (the nodes have a `NoSchedule` taint). An init container runs `talosctl etcd snapshot` against the local node. A second container uploads the file to S3 and deletes objects older than 7 days.
- A snapshot is about **141 MiB**. Seven days is about 4 GiB.
- It uses a talosconfig with only the `os:etcd:backup` role. The Secret `etcd-backup-talosconfig` is SOPS-encrypted in `k8s/infrastructure/infra-secrets/app/`. **The certificate expires on 2027-11-16.** Rotate it before then:

```bash
talosctl -n 192.168.1.145 config new --roles=os:etcd:backup --crt-ttl=8760h /tmp/etcd-backup
# put the file content into secret-etcd-backup-talosconfig.yaml (key: config), then:
sops --encrypt --in-place k8s/infrastructure/infra-secrets/app/secret-etcd-backup-talosconfig.yaml
shred -u /tmp/etcd-backup
```

- `talosctl config new` fails with "not supported with multiple nodes" unless you pass a single `-n <ip>`.
- The S3 credentials Secret `etcd-backup-s3` is a copy of Velero's `credentials-sw`. Update both if the S3 keys change.
- Run one now: `kubectl -n backup create job --from=cronjob/etcd-snapshot etcd-snapshot-manual`. Delete the Job after.
- **Restore is manual and destructive.** Download a snapshot from `s3://velero/etcd/` and follow the Talos disaster recovery procedure (`talosctl bootstrap --recover-from=<file>`). It has not been tested.

### Reading the backup bucket

Use the Velero credentials, not `scripts/s3-env.sh`:

```bash
CREDS=$(kubectl -n kube-system get secret credentials-sw -o jsonpath='{.data.cloud}' | base64 -d)
export AWS_ACCESS_KEY_ID=$(printf '%s\n' "$CREDS" | awk -F' *= *' '/aws_access_key_id/{print $2}')
export AWS_SECRET_ACCESS_KEY=$(printf '%s\n' "$CREDS" | awk -F' *= *' '/aws_secret_access_key/{print $2}')
export AWS_DEFAULT_REGION=default AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
aws s3 ls s3://velero/ --endpoint-url http://192.168.1.231:30304
```

Do not print the credential values.

## Removing a node (runbook)

1. **Worker with an OSD:** make sure Ceph is `HEALTH_OK` and PGs are `active+clean`. Then scale down the OSD deployment, run `kubectl rook-ceph ceph osd purge <id> --yes-i-really-mean-it`, run `kubectl rook-ceph ceph osd crush remove <host>`, and delete the `rook-ceph-osd-<id>` deployment.
2. **Control plane node:** run `talosctl etcd remove-member <id>` first. Keep an odd number of members.
3. Run `kubectl delete node <name>`. If the node is alive, use `talosctl reset --graceful` before this step. Do not run `kubectl drain` on a dead node. It hangs.
4. Remove the node IP from `flake.nix` (`CONTROL_PLANE_NODE_IPS` or `WORKER_IPS`), delete its `patch-*.yaml`, and delete the Proxmox VM.
5. Check: `kubectl get nodes`, `talosctl get members`, `kubectl rook-ceph ceph osd tree`, `talosctl health`.

## Common gotchas

- `ks.yaml` and `kustomization.yaml` files are Flux entrypoints. Edits inside a directory have no effect if the parent kustomization does not include it. New apps must be added to `k8s/apps/kustomization.yaml`.
- GPU workloads (Open WebUI) need the NVIDIA operator (`k8s/infrastructure/nvidia-operator`) and nodes with the NVIDIA factory image and the kernel module patch.
- Kustomizations that fail do not block the rest of Flux. Check `flux get kustomizations` for `False` entries.
- Velero does **not** back up etcd. etcd has its own CronJob. See [Backups](#backups).
- A new app namespace is **not** backed up until you add the `backup.grendel71.net/enabled: "true"` label. See [Backups](#backups).
