# Cilium migration runbook (Flannel + kube-proxy → Cilium)

> Operator-only document. Flux ignores `.md`, so this folder is intentionally
> not kustomized. Nothing here is applied automatically — a human runs these
> steps from a shell with the dev shell active (`direnv allow` or `nix develop`).
> **Every command block is for `bash`** (arrays, `[[ ]]`, `read -r`), run from the
> repo root, in **one shell session** that you keep open for the whole window
> (the helper functions and arrays live in it). Do not use `set -e` in that shell;
> the helpers return non-zero on failure and the loops stop with `|| break`.

**Goal:** replace the Talos-bootstrapped Flannel CNI and kube-proxy with Cilium
(kube-proxy replacement + Hubble), managed by Flux.

> **STATUS: EXECUTED on 2026-11-16/17.** The cutover is done (§9 has what actually
> happened and the corrections to this runbook). The text below is kept as the
> procedure for a rebuild or a rehearsal. `cilium` and `cilium-routes` are
> **no longer suspended** in git; do not re-suspend them (§7).

**State in git (before the cutover):** the `cilium` and `cilium-routes` Flux Kustomizations were
**GATED** (`suspend: true`). Merging to `main` did **not** install Cilium, but it
is not a no-op. It (1) changes the `payments` HTTPRoute (moved to `envoy-internal`,
host `papi.internal.grendel71.net`, applied at the next reconcile of `payments`),
(2) adds the `cilium` HelmRepository (to `sources`, see §0), (3) adds the
suspended `cilium` and `cilium-routes` Kustomizations, and (4) adds
`cilium-policies`, which stays Ready=False ("dependency not ready", retried every
2m) until the cutover. Nothing else. The cutover is a separate commit that sets
`suspend: false` (§3).
**NEVER use `flux resume` for `cilium` or `cilium-routes`:** a resumed
Kustomization reconciles immediately and installs Cilium outside the runbook
order; the parent `flux-system` Kustomization only reverts the flag at its next
reconcile. (`flux resume` is fine for the app Kustomizations suspended in §2b.)
`cilium-policies` is gated **only** by its `dependsOn: cilium`: removing that
dependency from `cilium-policies/ks.yaml` un-gates it. Its policies stay inert
while `policyEnforcementMode: never`.

---

## 0. Strategy and blast radius

**Declared maintenance window: cluster-wide pod-to-pod network outage between the
moment the first Cilium agent starts and the last node reboot (about 30–60 min).
Existing pods keep running on their old IPs until their node reboots. Expect
Flux, CNPG, Ceph clients and Envoy Gateway to be disrupted.**

**This window takes SSO offline.** Authentik (`ak.grendel71.net`) and its database
are down for the whole window: §2b suspends the `authentik` Kustomization and
hibernates `authentik-db` (CNPG), so everything that logs in through Authentik
cannot authenticate. The other consumers in the §2b table go down too (Immich,
Nextcloud, Vaultwarden, LiteLLM, Open WebUI, Jellyfin, the *arr stack, the payments
DB and so on). Schedule accordingly and warn users.

Why: Flannel and Cilium would both own `10.244.0.0/16` (`ipam.mode: kubernetes`
reuses the node podCIDRs) and cannot interoperate. Flannel's overlay is VXLAN on
UDP 4789, Cilium's on UDP 8472, so nodes on different CNIs form two islands that
cannot reach each other's pods. Cilium's official zero-downtime migration
(<https://docs.cilium.io/en/stable/installation/k8s-install-migration/>) needs a
distinct pod CIDR plus `CiliumNodeConfig` and per-node rollout. We declined that
as too complex. The same page says plainly that this naive variant splits the
cluster into "two islands of connectivity" and that **a trial migration on a test
cluster is strongly recommended** (§1a).

What keeps working during the window (host-network, independent of the CNI): the
Talos API, etcd, kube-apiserver, kubelet, KubePrism (`localhost:7445`, used by
Cilium and kubelet to reach the API), kube-vip (VIP `192.168.1.100`) and MetalLB
speakers. **But** kube-vip reaches the API through the `10.96.0.1` ClusterIP (it
has no `KUBERNETES_SERVICE_HOST` override), which after a node reboot depends on
Cilium's socket-LB instead of kube-proxy. If kube-vip loses its lease the VIP
drops and **both CLIs lose their endpoint** (their configs point only at the
VIP). Hence §2b sets up direct node access and §4 gates on kube-vip.

What does **not** work: anything pod-to-pod across islands, and anything that
goes through a cross-node ClusterIP service:

- **Ceph.** Mons run on pod IPs: `c` on talos-i4x-2pd (worker), `d` on
  talos-47z-ayo (CP), `e` on talos-1i8-qm9 (CP). OSDs run on the 4 workers (pod
  IPs). The RBD/CephFS CSI plugins are hostNetwork. A rebooted worker (Cilium
  island) cannot reach the mons until two of the three mons are on Cilium, which
  is only the case after talos-i4x-2pd (`c`) **and** talos-1i8-qm9 (`e`) have
  rebooted. Expected **total storage outage span: from the first worker reboot
  until talos-1i8-qm9 is back and the OSDs have reconnected**, plus recovery
  after the last node. Kernel RBD mounts with hung I/O can block `talosctl reboot`
  (default timeout 20 min) and kubelet. So all RBD consumers are stopped first
  (§2b). Rebooting the mon hosts earlier is **not** recommended: it only helps
  if every gate is real, and a mid-window mon reboot costs quorum.
- **Cluster DNS** (CoreDNS pods on Flannel IPs) for pods on the other island, and
  **hubble-relay / hubble-peer** (peer discovery goes through cluster DNS): Hubble
  UI shows nothing until the end.
- Envoy proxies reaching backends, Flux controllers reaching each other, CNPG
  replication/clients.
- **Webhooks and aggregated APIs.** The apiserver (host network) calls
  admission webhooks and aggregated APIs on pod IPs, so across islands they time
  out. Webhooks with `failurePolicy: Fail` on this cluster (verified live with
  `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations`):
  `cdi-api-pvc-mutate` (**can block PVC creation**), `mutate-runner-pod.webhook.actions.summerwind.dev`
  (**can block runner pod creation**), `cnpg-*` (any Cluster/Pooler/Backup change),
  `cert-manager-webhook`, MetalLB, `virt-api-*`/`kubevirt-*`. Aggregated APIs:
  `v1beta1.metrics.k8s.io`, `*.subresources.kubevirt.io`, `v1beta1.upload.cdi.kubevirt.io`
  (`kubectl top` and discovery warnings are expected). **Create no PVCs, no CNPG
  changes and no runner pods in the window.**

**Helm source risk.** The `sources` Kustomization (`wait: true`) now includes the
`cilium` HelmRepository: if `helm.cilium.io` is unreachable, `sources` and every
Kustomization that depends on it become not Ready. Check `flux get sources helm -A`
before the window.

Pods get **new IPs** when their node reboots.

Consequences for the procedure:

- Do everything that needs a working Flux/pod network **before** the first Cilium
  agent starts (merge, reconcile, hibernation).
- Do not "wait for green" mid-window on anything that crosses the pod network.
  The strict Ceph gates apply **before the first reboot** and again in §5
  **before `osd unset noout`**.
- Keep the window short: reboot back-to-back once the old stack is deleted.

## 1. Pre-checks (all must pass before starting)

Run in bash. Use the normal (VIP) access here.

```bash
# every node Ready, versions as expected (2 CP + workers on 1.13.0, 1i8-qm9 and i4x-2pd on 1.12.6)
kubectl get nodes -o wide

# talosctl client must be >= v1.13 (upgrade-k8s pruning / inventory behaviour is 1.13+)
v=$(talosctl version --client | awk '/Tag:/{print $2}'); echo "talosctl client $v"
printf '%s\n%s\n' v1.13.0 "$v" | sort -V -C && echo "talosctl OK" || echo "FAIL: talosctl client < v1.13.0"

# KubePrism: in-cluster kubeconfig points at localhost:7445 and every node's KubePrism is healthy
kubectl -n kube-system get cm kubeconfig-in-cluster -o yaml | grep server     # server: https://127.0.0.1:7445
talosctl get kubeprismstatuses                                                 # HEALTHY true on all 7 nodes

# API reachable through the VIP, and who holds it (kube-vip leader)
kubectl --server https://192.168.1.100:6443 get --raw /readyz; echo
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'

# etcd: 3 members, none learner, no errors
talosctl --nodes 192.168.1.145,192.168.1.176,192.168.1.154 etcd status
talosctl --nodes 192.168.1.154 etcd members

# kube-vip healthy; how it reaches the API (no KUBERNETES_SERVICE_HOST override => ClusterIP 10.96.0.1)
kubectl -n kube-system get ds kube-vip-ds
kubectl -n kube-system get ds kube-vip-ds -o jsonpath='{.spec.template.spec.containers[0].env[*].name}{"\n"}'
kubectl get svc kubernetes

# Ceph: HEALTH_OK, all PGs active+clean, mon quorum 3/3
kubectl rook-ceph ceph status
kubectl rook-ceph ceph osd tree
kubectl -n rook-ceph get pods -o wide | grep -E 'mon-|osd-[0-9]'      # mon placement as in §0

# Baselines to diff against after the migration (pre-existing failures are normal;
# at the time of writing: jellyfin/searxng Kustomizations, some Error/CrashLoop pods)
flux get kustomizations > /tmp/ks-before.txt
kubectl get pods -A | grep -vE 'Running|Completed' > /tmp/pods-before.txt
kubectl get clusters.postgresql.cnpg.io -A

# etcd snapshot, stored OUTSIDE the repo
mkdir -p ~/backups/etcd
talosctl --nodes 192.168.1.154 etcd snapshot "$HOME/backups/etcd/pre-cilium-$(date +%Y%m%d-%H%M%S).db"

# Velero backup completes
velero backup create pre-cilium --wait
velero backup get
```

**NetworkPolicy warning.** `policyEnforcementMode` is `never` in
`release.yaml`, so the existing NetworkPolicies are **NOT enforced** during and
after the migration (Flannel never enforced them either). Do not flip it to
`default` before the Phase 2 audit:

```bash
kubectl get netpol -A
```

| Namespace | NetworkPolicy | Pod selector (live) |
|---|---|---|
| flux-system | allow-egress, allow-scraping | all pods |
| flux-system | allow-webhooks | `app=notification-controller` |
| payments | payments-platform | `app.kubernetes.io/instance=payments-platform,app.kubernetes.io/name=payments-platform` |
| payments | payments-platform-migrate | `app.kubernetes.io/component=migration,app.kubernetes.io/instance=payments-platform,app.kubernetes.io/name=payments-platform-migration` |

**Payments caveat (broken as written).** `payments-platform` allows ingress to
port 8000 only from pods in `envoy-gateway-system` labelled
`app.kubernetes.io/name=envoy-gateway`. Read-only check of the real labels:

```bash
kubectl -n envoy-gateway-system get pods --show-labels
```

Result when this runbook was written: **no pod carries
`app.kubernetes.io/name=envoy-gateway`**.

- Envoy Gateway controller (`envoy-gateway-…`): `app.kubernetes.io/name=gateway-helm`,
  `app.kubernetes.io/instance=envoy-gateway`, `control-plane=envoy-gateway`.
- Envoy proxy pods (`envoy-envoy-gateway-system-<gateway>-…`, the ones that
  actually forward traffic): `app.kubernetes.io/name=envoy`,
  `app.kubernetes.io/component=proxy`, `app.kubernetes.io/managed-by=envoy-gateway`,
  `gateway.envoyproxy.io/owning-gateway-name=<envoy-external|envoy-internal|envoy-nx|tcp-gateway>`.

So enforcing that policy would block all ingress to payments. The Phase 2 audit
must change its selector to the **proxy** pods (e.g. `app.kubernetes.io/name=envoy`
+ `gateway.envoyproxy.io/owning-gateway-name=envoy-internal`, since `papi` moves
to the internal gateway) before `policyEnforcementMode` is set to `default`. The
policy comes from the `payments-platform` Helm chart (0.2.4) values.

### 1a. Prerequisite: rehearse §2–§4 on a throwaway cluster

Do **not** run the window before this passes. The Cilium migration guide says a
trial migration is "strongly recommended", and these assumptions of this runbook
are **untested**:

1. A throwaway **3-node Talos cluster** (e.g. 1 CP + 2 workers, or 3 CP with
   scheduling enabled) with the **same Talos versions** (mix of v1.12.6 and
   v1.13.0), Kubernetes v1.35.2, Flannel + kube-proxy as bootstrapped, pod CIDR
   `10.244.0.0/16`, KubePrism on.
2. Apply the same §2 patch, install Cilium with the exact `release.yaml` values
   (e.g. `helm template` + `kubectl apply`, or a scratch Flux), then run §3–§4
   with the helpers from §2b (adjust the IP arrays).
3. Record the answers to: (a) does the Flannel data path survive while the Cilium
   agents run (§3 probe), and does flanneld keep its FDB/routes? (b) does
   `cni.exclusive` rename `10-flannel.conflist` and does `cni.uninstall: true`
   restore it (§7)? (c) does deleting the flannel/kube-proxy DaemonSets leave links
   and rules in place until reboot? (d) can Cilium's router IP / pod IPs collide
   with `cni0` (`.1`) and Flannel host-local allocations while both CNIs share the
   same per-node /24? (e) do the helper greps match the real `cilium-dbg status
   --verbose` output of 1.20.4 (`KubeProxyReplacement: True`, `Socket LB: Enabled`,
   `Cluster health: N/N reachable`)? (f) the §7 rollback incl. the host-local
   cleanup. (g) Does `Cluster health` reach N/N on a rebooted node while the
   other nodes are still on Flannel? (`wait_node` treats it as a soft check
   because this is unproven.)
4. Fix this document with whatever differs, then schedule the real window.

## 2. Talos machine config patch (all 7 nodes, no reboot)

```bash
cat > /tmp/cilium-cni-patch.yaml <<'EOF'
cluster:
  network:
    cni:
      name: none      # stop rendering the Flannel bootstrap manifest
  proxy:
    disabled: true    # stop rendering the kube-proxy bootstrap manifest
EOF

# sanity check on one node first
talosctl patch mc --dry-run --patch @/tmp/cilium-cni-patch.yaml --nodes 192.168.1.154

for ip in 192.168.1.145 192.168.1.176 192.168.1.154 \
          192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233; do
  talosctl patch mc --mode=no-reboot --patch @/tmp/cilium-cni-patch.yaml --nodes "$ip" || break
done

# verify: on control planes 05-flannel and 10-kube-proxy must be gone from the rendered manifests
talosctl --nodes 192.168.1.154 get manifests
talosctl --nodes 192.168.1.154 get mc -o yaml | grep -nE 'name: none|disabled: true'

# READ-ONLY preview of what a later `upgrade-k8s` would prune. Never run it without --dry-run in the window.
talosctl --nodes 192.168.1.154 upgrade-k8s --to 1.35.2 --dry-run
```

What this does: the patch is applied immediately, but it only changes the
**bootstrap manifests Talos renders**. **Nothing that already runs is deleted**:
the `kube-flannel` and `kube-proxy` DaemonSets, `flannel.1`, `cni0`, iptables
rules and `/etc/cni/net.d/10-flannel.conflist` all stay. Talos v1.13+ only prunes
rendered-away manifests when `talosctl upgrade-k8s` runs (hence the client check
in §1), so **do not run `upgrade-k8s` during the window**. Its job is done by the
deletions in §3. (After the migration a later `upgrade-k8s` finds nothing to prune.)

Leftovers: `flannel.1`, `cni0` and the old iptables rules disappear at reboot.
`/etc/cni` is **not** cleared by a reboot: on Talos it is an overlay persisted
under `/var/system/overlays/etc-cni-diff`. Cilium (`cni.exclusive: true`) renames
`10-flannel.conflist` to `10-flannel.conflist.cilium_bak` and writes
`05-cilium.conflist`; both persist (harmless while Cilium is the CNI, relevant for
rollback in §7). **`/var/lib/cni/networks/cbr0` (Flannel's host-local IP
reservations) also persists** and is not cleaned up by Cilium (§7).

**Talos version note.** Both patch forms above are for Talos < v1.14 (all nodes
here are 1.12.6 or 1.13.0). Talos ≥ v1.14 replaces them with
`KubeFlannelCNIConfig` (`$patch: delete`) and `KubeProxyConfig`
(`enabled: false`) documents (per
<https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium>).

**Local configs.** The git-ignored `talos-infra/` machine configs
(`controlplane.yaml`, `worker.yaml`, `workernvme.yaml`, `workernvidia.yaml`,
`controllaptop.yaml`, `controlmaster.yaml`) must get the same two keys by hand.
Otherwise a later `talosctl apply-config` re-introduces Flannel/kube-proxy.

## 2b. Quiesce storage and prepare access (immediately before §3)

### Quiesce RBD consumers and CNPG

Why: Ceph is unusable for most of the window (§0), and a pod with a kernel RBD
mount and hung I/O blocks `talosctl reboot`. There is **no CephFS PVC** on this
cluster; the only Ceph volumes are RBD PVCs of StorageClass
`replicated-x3-block-store` (Retain). The `slow` PVs are static NFS to
`192.168.1.231` (LAN IP, not a Service, so socket-LB does not touch them) and
need no quiescing.

Flux would put replicas and annotations back, so **suspend the owners first**
(live-derived 2026-11 from `kubectl get clusters.postgresql.cnpg.io -A`, the PVC
list and the Helm release labels; re-derive with those commands, the list drifts):

| Namespace | Workload (RBD) | Flux owner (Kustomization → HelmRelease) |
|---|---|---|
| apps | CNPG `example-pg` | `example-db` |
| authentik | CNPG `authentik-db` | `authentik` |
| immich | CNPG `immich-postgres` | `immich` |
| leaderboard | CNPG `leaderboard-db` | `leaderboard` |
| lifter | CNPG `lifter-db` | `lifter` |
| litellm | CNPG `litellm-db`; `litellm-redis` (Redis CR, sts) | `litellm` → HR `litellm`, `litellm-redis` |
| nextcloud-new | CNPG `nextcloud-db`; deploy `nextcloud` | `nextcloud` → HR `nextcloud` |
| pappwiki | CNPG `pappwiki-db` | `pappwiki` |
| payments | CNPG `payments-db` | `payments` |
| ai | deploy `hermes` | `hermes-agent` → HR `hermes` |
| apps | deploy `firefox`, `jellyfin`, `searxng`, `searxng-valkey`, `syncthing`, `open-webui-pipelines`; sts `open-webui` | `firefox`, `jellyfin`, `searxng`, `syncthing`, `open-webui` (HR of the same names) |
| torrent | deploy `prowlarr`, `radarr`, `sonarr`, `qbittorrent` | `arr` (HR `prowlarr`/`radarr`/`sonarr`), `qbittorrent` |
| vaultwarden | sts `vaultwarden`; `bw-portal-redis` (Redis CR, sts) | `vaultwarden` → HR `vaultwarden`, `bw-portal-redis` |

The Redis StatefulSets are owned by the `redis-operator` (Deployment in
`kube-system`, HR `redis-operator` in `flux-system`, Kustomization
`infra-releases`), which would scale them back up: stop the operator first. The
CNPG operator (`cnpg-system`) must keep running: it performs the hibernation.

```bash
# 1. Suspend the Flux owners (NEVER cilium / cilium-routes here)
KS_SUSPEND=(example-db authentik immich leaderboard
            lifter litellm nextcloud pappwiki payments hermes-agent firefox jellyfin searxng syncthing
            open-webui arr qbittorrent vaultwarden)
HR_SUSPEND=(ai/hermes apps/firefox apps/jellyfin apps/searxng apps/syncthing apps/open-webui
            litellm/litellm litellm/litellm-redis nextcloud-new/nextcloud torrent/prowlarr torrent/radarr
            torrent/sonarr torrent/qbittorrent vaultwarden/vaultwarden vaultwarden/bw-portal-redis
            flux-system/redis-operator)
for ks in "${KS_SUSPEND[@]}"; do flux suspend kustomization "$ks" || break; done
for hr in "${HR_SUSPEND[@]}"; do flux suspend helmrelease "${hr#*/}" -n "${hr%%/*}" || break; done
```

```bash
# 2. Record replicas, then hibernate CNPG and scale the consumers to zero
WIN=$(mktemp -d)                         # also used by §2b access setup below; keep this shell
WORKLOADS=(ai/deploy/hermes apps/deploy/firefox apps/deploy/jellyfin apps/deploy/searxng
           apps/deploy/searxng-valkey apps/deploy/syncthing
           apps/deploy/open-webui-pipelines apps/statefulset/open-webui
           nextcloud-new/deploy/nextcloud torrent/deploy/prowlarr torrent/deploy/radarr
           torrent/deploy/sonarr torrent/deploy/qbittorrent vaultwarden/statefulset/vaultwarden
           litellm/statefulset/litellm-redis vaultwarden/statefulset/bw-portal-redis)
for w in "${WORKLOADS[@]}"; do
  IFS=/ read -r ns kind name <<<"$w"
  echo "$w $(kubectl -n "$ns" get "$kind/$name" -o jsonpath='{.spec.replicas}')"
done | tee "$WIN/replicas.txt"

# CNPG: every cluster (the list from §1), then wait until no instance pod is left
kubectl get clusters.postgresql.cnpg.io -A --no-headers | while read -r ns name _; do
  kubectl -n "$ns" annotate clusters.postgresql.cnpg.io "$name" cnpg.io/hibernation=on --overwrite
done
kubectl get pods -A -l cnpg.io/cluster                                    # must become empty

# Redis: operator first (it would scale the StatefulSets back up), then the consumers
kubectl -n kube-system scale deploy/redis-operator --replicas=0
while read -r w _; do
  IFS=/ read -r ns kind name <<<"$w"
  kubectl -n "$ns" scale "$kind/$name" --replicas=0
done < "$WIN/replicas.txt"

# Gate: no RBD volume may be attached/mounted any more, no pod may mount an RBD PVC
kubectl get volumeattachments -o custom-columns=ATTACHER:.spec.attacher,NODE:.spec.nodeName,PV:.spec.source.persistentVolumeName --no-headers \
  | grep rbd || echo "no RBD attachments"
```

Do not continue while the last command lists attachments (wait; investigate the
pod that still holds the volume). Pods of `payments`/`immich` etc. that are
stateless keep running; they will be unreachable across islands, which is part of
the declared outage.

### Direct access fallback (kubectl and talosctl without the VIP)

Both CLIs point at the VIP only (`talosctl config info` shows `Endpoints:
192.168.1.100`; kubectl uses `https://192.168.1.100:6443`). If kube-vip loses its
lease both CLIs hang. The API certificate **does include the node IPs**
(verified: SANs of the apiserver cert on `.145` and `.154` list `192.168.1.100`,
the node IP, `10.96.0.1`, `127.0.0.1`, `localhost`, the hostname; `kubectl --server
https://<CP-IP>:6443 get --raw /readyz` returned `ok` on all three CPs with normal
verification), so **no `--tls-server-name` or insecure-skip is needed**. Talos adds
the node's own addresses to the SANs even though `certSANs: []` in
`talos-infra/controlplane.yaml`. The CLIs work with the **copies** below, which
the helpers re-point; the real configs stay untouched.

```bash
CPS=(192.168.1.145 192.168.1.176 192.168.1.154)
WORKERS=(192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233)
VIP=192.168.1.100

ORIG_KUBECONFIG=$KUBECONFIG; ORIG_TALOSCONFIG=$TALOSCONFIG
WIN=${WIN:-$(mktemp -d)}
install -m 600 "$KUBECONFIG" "$WIN/kubeconfig"
install -m 600 "$TALOSCONFIG" "$WIN/talosconfig"
export KUBECONFIG="$WIN/kubeconfig" TALOSCONFIG="$WIN/talosconfig"

# use_cp ip [ip...]: kubectl -> the first ip, talosctl -> all ips (never the VIP)
# WARNING: in a direnv shell, leaving and re-entering the repo directory can reset the exported
# KUBECONFIG/TALOSCONFIG to the originals. Re-export the copies first
# (export KUBECONFIG="$WIN/kubeconfig" TALOSCONFIG="$WIN/talosconfig"), then re-run use_cp.
use_cp() {
  local cl
  cl=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}') || return 1
  kubectl config set-cluster "$cl" --server "https://$1:6443" >/dev/null || return 1
  talosctl config endpoint "$@" >/dev/null || return 1
  echo "access via: $*"
}

# space-separated CPs except $1
others_of() { local x; for x in "${CPS[@]}"; do [[ $x != "$1" ]] && printf '%s ' "$x"; done; echo; }

confirm() { local a; read -r -p "$1 [y/N] " a; [[ $a == [yY]* ]]; }

# node name for an InternalIP (fails if there is none)
node_name() {
  local n
  n=$(timeout 30 kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
      | awk -v ip="$1" '$2==ip{print $1}')
  [[ -n $n ]] || { echo "FAIL: no node with InternalIP $1" >&2; return 1; }
  echo "$n"
}

use_cp "${CPS[@]}" && kubectl get nodes && talosctl --nodes "${CPS[0]}" version | head -3
```

If `use_cp` or the last line fails, **do not start the window**.

## 3. Cutover (the window starts here)

**Order and why.**

1. `noout` first (Ceph must not rebalance while OSDs disappear).
2. Two **probe pods** on Flannel IPs (the only objects created in the window
   before §5; they are deleted in step 6), so a broken pod network is detected
   instead of assumed.
3. **Cordon the 4 workers** just before un-suspending Cilium. Why: until a node
   reboots, Flannel and Cilium both use the **same per-node podCIDR**
   `10.244.N.0/24` on it (`cni0` is `.1`; Flannel allocates with host-local
   state, Cilium with its own allocator and router IP). A pod created in between
   could get an address that collides. Cordoned workers take no new pods; each is
   uncordoned after its reboot is verified (§4). The **control planes are not
   cordoned** (they already carry the `NoSchedule` control-plane taint, so only
   pods that tolerate it can land): the chart's `cilium-operator` (2 replicas,
   required anti-affinity, hostNetwork) tolerates the control-plane taint but
   **not** the `node.kubernetes.io/unschedulable` taint a cordon adds (checked in
   chart 1.20.4 `operator.tolerations`), so cordoning the CPs would leave the
   operator Pending and the `cilium` Kustomization/health check hang.
4. Un-suspend Cilium and wait for all agents Ready. Reasoning for **Cilium first,
   Flannel deletion after**: with Cilium installed while Flannel and kube-proxy are
   still there, nodes that have not rebooted keep as much of their old data path as
   possible (flanneld keeps its FDB, kube-proxy keeps syncing Service endpoints, so
   ClusterIPs keep working longest). Flux and the Helm install need the pod network,
   so this is the last moment they are reliable. Failure modes accepted: (a) Cilium
   installs routes for remote podCIDRs that may override Flannel's
   `10.244.N.0/24` routes, breaking Flannel pod-to-pod early (probe in step 5);
   (b) the router IP / `cilium_host` may collide with `cni0` (`.1`) (check in
   step 5); (c) `cni.exclusive` renames `10-flannel.conflist` on every node at agent
   start, so nodes cannot create Flannel pods from then on (hence the cordon).
5. **Probe** (below); on failure **STOP and decide**.
6. Delete Flannel and kube-proxy **immediately after the rollout and the probe**,
   before the first reboot. Otherwise the DaemonSets start again on every rebooted
   node, rewrite the Flannel CNI config and install kube-proxy iptables next to
   Cilium. Neither flanneld nor kube-proxy is expected to clean up its links/rules
   when its pod stops, so deleting the DaemonSets should not cause the outage by
   itself (leftovers go at reboot; untested, §1a).
7. Reboot all nodes one by one (§4): workers first, control planes last.

```bash
# 1. Ceph: do not mark OSDs out while they are unreachable
kubectl rook-ceph ceph osd set noout

# 2. Probe pods on two workers (Flannel IPs, created BEFORE Cilium takes over the CNI config)
kubectl run netcheck-a --image=busybox:1.37 --restart=Never --overrides='{"spec":{"nodeName":"talos-hjl-umn"}}' -- sleep 7200
kubectl run netcheck-b --image=busybox:1.37 --restart=Never --overrides='{"spec":{"nodeName":"talos-xyn-p5v"}}' -- sleep 7200
kubectl wait --for=condition=Ready pod/netcheck-a pod/netcheck-b --timeout=180s
A_IP=$(kubectl get pod netcheck-a -o jsonpath='{.status.podIP}'); B_IP=$(kubectl get pod netcheck-b -o jsonpath='{.status.podIP}')
echo "A=$A_IP B=$B_IP"
probe() {
  timeout 30 kubectl exec netcheck-a -- ping -c 3 -W 2 "$B_IP" &&
  timeout 30 kubectl exec netcheck-b -- ping -c 3 -W 2 "$A_IP" &&
  timeout 30 kubectl exec netcheck-a -- timeout 8 nslookup kubernetes.default.svc.cluster.local
}
probe && echo "PROBE BASELINE OK"            # must pass before going on

# 3. Cordon the workers (not the CPs, see above)
for ip in "${WORKERS[@]}"; do kubectl cordon "$(node_name "$ip")" || break; done
kubectl get nodes
```

```bash
# 4. Cutover commit: suspend: false on cilium and cilium-routes (NOT flux resume)
sed -i 's/^  suspend: true # GATED.*/  suspend: false # CUTOVER done, see MIGRATION.md/' \
  k8s/infrastructure/cilium/ks.yaml k8s/infrastructure/cilium/routes-ks.yaml
git diff --stat
git add k8s/infrastructure/cilium/ks.yaml k8s/infrastructure/cilium/routes-ks.yaml
git commit -m "feat(cilium): cutover, un-suspend cilium Kustomizations"
# merge to main (PR), then:
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization cilium

kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m
kubectl -n kube-system get pods -l k8s-app=cilium -o wide        # 7 pods Running, one per node
timeout 30 kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -E 'KubeProxyReplacement|Socket LB|Cluster health'
```

The HelmRelease has `install.disableWait: true` for the cutover, so it does not
wait for Hubble relay/UI (which cannot be Ready across islands, and whose pods are
also Pending on cordoned workers). The gate is the `rollout status` above. If
`flux get hr -n kube-system cilium` shows a failed release, **do not uninstall or
roll back** (remediation is disabled on purpose, `retries: 0`). Read
`kubectl -n kube-system describe hr cilium`, fix the cause, and after the window
force a retry with `flux reconcile helmrelease cilium -n kube-system --force`.
Un-suspending also un-gates `cilium-policies` (it `dependsOn: cilium`); its
policies are inert while `policyEnforcementMode: never`.

```bash
# 5. Probe again + collision check (read-only except the exec)
probe && echo "PROBE AFTER CILIUM OK" || echo "PROBE FAILED: STOP, decide below"
talosctl --nodes 192.168.1.103 get addresses | grep -E 'cilium_host|cni0'     # same /24: .1 on cni0 vs the router IP of cilium_host must differ
```

**STOP and decide if the probe fails.** A failure means the Flannel data path is
already gone (the window outage has started). Do not delete anything yet. Read
`kubectl -n kube-system logs ds/cilium -c cilium-agent --tail=50`. Decide:

- **A. Continue (default).** The outage is the declared cost: go straight on with
  step 6 and the §4 reboots without pausing. Choose this unless the logs show a
  Cilium misconfiguration that a retry would fix.
- **B. Abort.** Only possible before step 6 (the Flannel DaemonSet still exists):
  follow §7 now. Because the agents already renamed `10-flannel.conflist`, this is
  a **second window** (rolling reboot), not a quick undo.

```bash
# 6. Remove probes, Flannel and kube-proxy: exactly what Talos rendered (see `talosctl get manifests` before the patch)
kubectl delete pod netcheck-a netcheck-b --wait=false
kubectl -n kube-system delete ds kube-proxy kube-flannel
kubectl -n kube-system delete sa kube-proxy flannel
kubectl -n kube-system delete cm kube-flannel-cfg
kubectl delete clusterrolebinding kube-proxy flannel
kubectl delete clusterrole flannel
```

Never delete `kube-vip-ds` or the `metallb` speaker DaemonSet.

**Socket-LB and kernel clients.** `kubeProxyReplacement: true` enables Cilium's
socket-LB (eBPF cgroup hooks). Per the Cilium kube-proxy-free page it needs
`getpeername(2)` hook support for **libceph** (kernel RBD) clients; Talos here runs
kernel 6.18.x (all 7 nodes), which has it. Kernel NFS mounts to a Service ClusterIP
can break; ours use the LAN IP `192.168.1.231`.

## 4. Rolling reboot with gates (workers first, then control planes)

Never reboot two nodes at once. Paste the helpers once (they use the arrays,
`use_cp`, `others_of`, `confirm` and `node_name` from §2b):

```bash
# after a reboot: a NEW boot (bootID changed, so stale Ready/stale pod state cannot pass),
# node Ready, then Cilium checks on that node's agent. KPR True and Socket LB Enabled are
# HARD checks. "Cluster health: N/N" is SOFT: it is unproven while other nodes are still on
# Flannel (§1a), so if only it fails the operator decides. Every kubectl/talosctl call that
# can hang on a half-up node is wrapped in `timeout` (exit 124 = timed out; the loops treat
# it like an empty answer and retry).
wait_node() {   # wait_node <ip> <old-bootID>
  local ip=$1 old=$2 n new pod st hard_st i
  n=$(node_name "$ip") || return 1
  for i in $(seq 1 120); do                      # up to 20 min until the new boot shows up
    new=$(timeout 30 kubectl get node "$n" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null)
    [[ -n $new && $new != "$old" ]] && break
    sleep 10
  done
  [[ -n $new && $new != "$old" ]] || { echo "FAIL: $n bootID never changed" >&2; return 1; }
  timeout 630 kubectl wait --for=condition=Ready "node/$n" --timeout=600s || { echo "FAIL: $n not Ready" >&2; return 1; }
  for i in $(seq 1 60); do                       # up to 10 min until the agent passes
    pod=$(timeout 30 kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=$n" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    st=$([[ -n $pod ]] && timeout 30 kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --verbose 2>/dev/null)
    hard_st=
    if grep -Eq '^ *KubeProxyReplacement: +True' <<<"$st" \
       && grep -Eq '^ *Socket LB: +Enabled' <<<"$st"; then
      if awk '/^ *Cluster health:/ { split($3, a, "/"); ok = (a[1] == a[2] && a[2] > 0) } END { exit !ok }' <<<"$st"; then
        echo "OK: $n new boot, Ready, KPR + Socket LB on, cluster health full"
        return 0
      fi
      hard_st=$st                                # hard checks pass, only cluster health is short
    fi
    sleep 10
  done
  if [[ -n $hard_st ]]; then                     # ONLY the soft cluster-health check failed
    echo "WARN: $n has KPR + Socket LB on, but cluster health is not full. Full status:" >&2
    echo "$hard_st" >&2
    confirm "cluster health not full, continue?" && return 0
    echo "FAIL: stopped by operator, cluster health not full on $n" >&2
    return 1
  fi
  echo "FAIL: Cilium agent on $n not verified (KPR / Socket LB)" >&2
  return 1
}

# etcd: exactly 3 members, one leader, same raft term, none learner, no ERRORS, applied index within 1000
etcd_ok() {
  timeout 30 talosctl --nodes "$(IFS=,; echo "${CPS[*]}")" etcd status 2>/dev/null | awk '
    NR==1 { next }
    NF==0 { next }
    { for (i = 1; i <= NF; i++) if ($i ~ /%\)$/) break
      if (i > NF) { bad = 1; next }
      n++; lead[$(i+1)] = 1; term[$(i+3)] = 1; ap = $(i+4) + 0
      if (max == "" || ap > max) max = ap
      if (min == "" || ap < min) min = ap
      if ($(i+5) != "false") bad = 1
      if (NF > i+7) bad = 1 }
    END { for (k in lead) nl++; for (k in term) nt++
          exit !(n == 3 && !bad && nl == 1 && nt == 1 && max - min <= 1000) }'
}

# the VIP answers /readyz with exactly "ok" (retries up to ~2 min: kube-vip failover)
vip_ok() {
  local i
  for i in $(seq 1 24); do
    [[ $(kubectl --server "https://$VIP:6443" get --raw /readyz --request-timeout=5s 2>/dev/null) == ok ]] && return 0
    sleep 5
  done
  echo "FAIL: VIP $VIP does not answer /readyz with ok" >&2
  return 1
}

# control-plane gate: every check must pass, otherwise it returns 1
cp_gate() {
  local x
  timeout 200 kubectl -n kube-system rollout status ds/kube-vip-ds --timeout=180s \
    || { echo "FAIL: kube-vip-ds not fully ready" >&2; return 1; }
  for x in "${CPS[@]}"; do
    [[ $(kubectl --server "https://$x:6443" get --raw /readyz --request-timeout=10s 2>/dev/null) == ok ]] \
      || { echo "FAIL: /readyz on $x is not ok" >&2; return 1; }
  done
  etcd_ok || { echo "FAIL: etcd is not 3 healthy members in sync" >&2; return 1; }
  vip_ok || return 1
  echo "cp_gate OK"
}

# reboot one node and verify it; uncordon it only after wait_node passed
reboot_node() {   # reboot_node <ip>
  local ip=$1 n old
  n=$(node_name "$ip") || return 1
  old=$(timeout 30 kubectl get node "$n" -o jsonpath='{.status.nodeInfo.bootID}') || return 1
  [[ -n $old ]] || { echo "FAIL: empty bootID for $n" >&2; return 1; }
  echo "== rebooting $n ($ip), old bootID $old =="
  talosctl reboot --nodes "$ip" || { echo "FAIL: talosctl reboot $ip" >&2; return 1; }
  wait_node "$ip" "$old" || return 1
  timeout 30 kubectl uncordon "$n" || return 1
}

# one control plane: access only via the OTHER CPs, gate, operator confirmation, reboot, gate again
cp_step() {   # cp_step <ip>
  local ip=$1 oth
  read -ra oth <<<"$(others_of "$ip")"
  use_cp "${oth[@]}" || return 1                 # never the node being rebooted, never the VIP
  cp_gate || return 1
  confirm "reboot control plane $ip ($(node_name "$ip"))? continue" || { echo "stopped by operator"; return 1; }
  reboot_node "$ip" || return 1
  cp_gate || return 1
}
```

**Workers.** Gate before the **first** worker (strict baseline; stop if it fails):

```bash
use_cp "${CPS[@]}"
timeout 60 kubectl rook-ceph ceph status   # HEALTH_OK except the noout warning, all PGs active+clean, mon quorum 3/3
```

Between later workers Ceph is **expected to be degraded** (the rebooted workers'
OSDs sit on the Cilium island, the mons may still be on the Flannel island), so
`ceph status` can hang or show down OSDs and inactive PGs. That is not a reason
to stop. The gate for each following worker is: the previous node passed
`wait_node` (new boot, Ready, KPR + Socket LB on; cluster health full, or you
confirmed the "cluster health not full, continue?" prompt), and its
pods are Running (`kubectl get pods -A -o wide | grep <node>`).
Never run `osd out`, `osd purge` or `osd unset noout` in the window.

```bash
for ip in "${WORKERS[@]}"; do
  reboot_node "$ip" || { echo "STOP at worker $ip, investigate"; break; }
done
```

**Control planes.** Reboot the current kube-vip holder **last** (it holds
`plndr-cp-lock`; rebooting it forces a VIP failover). kube-vip reaches the API
through the `10.96.0.1` ClusterIP, which now depends on Cilium instead of
kube-proxy, so `cp_gate` verifies `kube-vip-ds` rollout, `/readyz` on all three
CPs (direct, not via the VIP), a real etcd check and the VIP, before and after
each reboot. One CP at a time, with an operator confirmation each time:

```bash
HOLDER=$(kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'); echo "VIP holder: $HOLDER"
HOLDER_IP=$(kubectl get node "$HOLDER" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
CP_ORDER=(); for x in "${CPS[@]}"; do [[ $x != "$HOLDER_IP" ]] && CP_ORDER+=("$x"); done; CP_ORDER+=("$HOLDER_IP")
echo "order: ${CP_ORDER[*]}"
for ip in "${CP_ORDER[@]}"; do
  cp_step "$ip" || { echo "STOP at control plane $ip, do not reboot the next one"; break; }
done
```

If any gate fails, do not reboot the next control plane. Wait for etcd to rejoin
(`talosctl etcd members`), and see "VIP lost" below if the VIP is missing.

### VIP lost (kube-vip lost its lease, both CLIs hang on `192.168.1.100`)

Nothing else uses the VIP: kubelet and Cilium use KubePrism
(`localhost:7445`, which load-balances over all CPs), so the cluster itself keeps
running. Only the CLIs and external clients need it.

```bash
# 1. Work through node IPs (use_cp re-points the copies; pick CPs that are up)
use_cp 192.168.1.145 192.168.1.176 192.168.1.154
# 2. Who holds the lease, are the kube-vip pods alive?
kubectl -n kube-system get lease plndr-cp-lock -o yaml | grep -E 'holderIdentity|renewTime'
kubectl -n kube-system get pods -l app.kubernetes.io/name=kube-vip-ds -o wide
kubectl -n kube-system logs ds/kube-vip-ds --tail=30
# 3. Does the ClusterIP work from the host namespace on that node? (Cilium socket-LB; set NODE first)
NODE=talos-xyz-abc
timeout 30 kubectl -n kube-system exec "$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=$NODE" -o name)" -c cilium-agent -- cilium-dbg service list | grep 10.96.0.1
# 4. Restart kube-vip (all three; the lease is re-elected within ~5 s)
kubectl -n kube-system delete pod -l app.kubernetes.io/name=kube-vip-ds
kubectl -n kube-system rollout status ds/kube-vip-ds --timeout=180s
```

If the pods keep failing on the node(s) not yet on Cilium, the cause is the
ClusterIP path (kube-proxy rules are gone at reboot; Cilium's agent on that node
must be up and `cilium-dbg service list` must list `10.96.0.1`): restart that
node's Cilium pod. Then `vip_ok` (from §4). To check a CP's Talos API without the
VIP: `talosctl --endpoints <CP-IP> --nodes <CP-IP> version`.

## 5. Post-checks

```bash
# Cilium healthy on every node, KPR active, no flannel/kube-proxy left
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
timeout 30 kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -E 'KubeProxyReplacement|Socket LB|Cluster health|Controller Status'
kubectl get ds -A | grep -E 'flannel|kube-proxy' || echo clean
kubectl get nodes -o wide                       # all Ready and schedulable (no SchedulingDisabled)

# control plane + VIP (use_cp is no longer needed once the VIP answers)
kubectl --server https://192.168.1.100:6443 get --raw /readyz; echo
kubectl get svc kubernetes                      # ClusterIP 10.96.0.1
kubectl -n kube-system get ds kube-vip-ds

# CoreDNS resolution: cluster names and external names (host DNS forwarding + hostLegacyRouting)
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.37 -- \
  sh -c 'nslookup kubernetes.default.svc.cluster.local && nslookup example.com'

# Envoy Gateway services are named envoy-<ns>-<gateway>-<hash>: read them, do not guess
kubectl -n envoy-gateway-system get svc
kubectl -n envoy-gateway-system get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}'
# expected (verified live when this runbook was written): envoy-external .67, envoy-internal .69,
# envoy-nx .71, tcp-gateway .72
kubectl get gateway -A                          # all PROGRAMMED True

# MetalLB VIPs reachable and served by Envoy (any HTTP status = OK; 000 / timeout = broken)
curl -sk -o /dev/null -w '%{http_code}\n' --resolve me.grendel71.net:443:192.168.1.67 https://me.grendel71.net/
curl -sk -o /dev/null -w '%{http_code}\n' --resolve open-webui.internal.grendel71.net:443:192.168.1.69 https://open-webui.internal.grendel71.net/
curl -sk -o /dev/null -w '%{http_code}\n' --resolve st.x.nx8192.win:443:192.168.1.71 https://st.x.nx8192.win/
timeout 5 bash -c '</dev/tcp/192.168.1.72/8088' && echo tcp-gateway-open
# Hubble UI, internal only
curl -sk -o /dev/null -w '%{http_code}\n' --resolve hubble.internal.grendel71.net:443:192.168.1.69 https://hubble.internal.grendel71.net/

# Ceph: skip the OSD crash-loop backoff after the last reboot, then require full recovery BEFORE removing noout.
# Gate first: all 3 mon pods Running and Ready (note: stale "Completed" pods of old ReplicaSets are normal).
timeout 30 kubectl -n rook-ceph get pods -l 'app in (rook-ceph-mon,rook-ceph-osd)' -o wide
mons_ok=$(timeout 30 kubectl -n rook-ceph get pods -l app=rook-ceph-mon --no-headers \
  | awk '{ split($2, a, "/"); if ($3 == "Running" && a[1] == a[2]) n++ } END { print n + 0 }')
if [[ $mons_ok -eq 3 ]]; then
  # delete ONLY OSD pods that are not Running/Completed (CrashLoopBackOff, Error, ...), never healthy OSDs
  timeout 30 kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers \
    | awk '$3 != "Running" && $3 != "Completed" { print $1 }' | xargs -r kubectl -n rook-ceph delete pod
else
  echo "STOP: only $mons_ok/3 mon pods Running+Ready; fix the mons before touching OSD pods"
fi
kubectl rook-ceph ceph status                   # HEALTH_OK except noout, PGs active+clean, mon quorum 3/3
kubectl rook-ceph ceph osd tree
kubectl rook-ceph ceph osd unset noout          # re-enables marking down OSDs "out" (not backfill)
kubectl rook-ceph ceph status                   # HEALTH_OK
```

**Restore storage consumers** (only after Ceph is HEALTH_OK; this is the matching
step of §2b). Order: operators, then CNPG, then Flux, then scale-up:

```bash
# 1. CNPG: un-hibernate (needs the cnpg-system pods reachable; webhooks must answer)
kubectl -n cnpg-system get pods
kubectl get clusters.postgresql.cnpg.io -A --no-headers | while read -r ns name _; do
  kubectl -n "$ns" annotate clusters.postgresql.cnpg.io "$name" cnpg.io/hibernation=off --overwrite
done

# 2. Redis operator, then the recorded replicas (before Flux resumes, so Flux sees the real state)
kubectl -n kube-system scale deploy/redis-operator --replicas=1
while read -r w r; do
  IFS=/ read -r ns kind name <<<"$w"
  if [[ -n $r ]]; then
    kubectl -n "$ns" scale "$kind/$name" --replicas="$r"
  else
    echo "SKIP: no recorded replica count for $w (scale it by hand)"
  fi
done < "$WIN/replicas.txt"

# 3. Resume the Flux owners suspended in §2b (NEVER touch cilium / cilium-routes here)
for hr in "${HR_SUSPEND[@]}"; do flux resume helmrelease "${hr#*/}" -n "${hr%%/*}"; done
for ks in "${KS_SUSPEND[@]}"; do flux resume kustomization "$ks"; done

# 4. CNPG healthy, RBD consumers back
kubectl get clusters.postgresql.cnpg.io -A
kubectl get pods -A | grep -vE 'Running|Completed' | diff /tmp/pods-before.txt - || true

# 5. Back to the real CLI configs, remove the temporary copies
export KUBECONFIG=$ORIG_KUBECONFIG TALOSCONFIG=$ORIG_TALOSCONFIG
rm -rf "$WIN"
talosctl config info | grep Endpoints          # 192.168.1.100 again
```

```bash
# Flux: every Kustomization Ready (compare with the baseline)
flux get kustomizations > /tmp/ks-after.txt; diff /tmp/ks-before.txt /tmp/ks-after.txt
flux get kustomizations | grep -v True || echo "all Ready"
flux get helmreleases -A | grep -v True || echo "all Ready"

# optional: needs the cilium CLI and a privileged test namespace (Talos PodSecurity)
# cilium connectivity test
```

## 6. After success: follow-up commit

A **separate** commit after §5 passes:

- Delete the `operator.unmanagedPodWatcher` block from `app/release.yaml`
  (restores the default `restart: true`: the operator restarts pods that are not
  managed by Cilium).
- Optional: delete `install.disableWait: true` (restores the Helm install wait).
- Leave `bpf.hostLegacyRouting: true` and `policyEnforcementMode: never`
  untouched here. `hostLegacyRouting` comes from the Cilium migration guide
  (`values-migration.yaml`: "Allow for routing between Cilium and the existing
  overlay"); it is **harmless to keep** after the migration (it only forgoes the
  optional eBPF host-routing speed-up). It is **not** a Talos requirement: the
  Cilium-on-Talos guide's Known issues only mention `forwardKubeDNSToHost` +
  `bpf.masquerade=true`. `policyEnforcementMode` becomes `default` **only in the
  Phase 2 commit**, together with the audited/verified policies (including the
  payments selector fix from §1).

## 7. Rollback

**Never run `talosctl bootstrap`.** It initialises etcd and is dangerous on a live
cluster; it is not a way to bring back Flannel.

- **Before the cutover commit:** nothing to roll back. The Kustomizations are
  suspended, nothing is installed. Revert the gate PR if wanted. If §2b ran,
  restore storage consumers as in §5 ("Restore storage consumers").
- **After the cutover commit:** pods that have already moved to Cilium stay
  there. Going back to Flannel after nodes have rebooted onto Cilium is a
  **second maintenance window**.

Steps (rollback procedure is **untested**; rehearse it in §1a):

```bash
# 1. Revert the Talos patch on all 7 nodes (Flannel + kube-proxy rendered again)
cat > /tmp/flannel-restore-patch.yaml <<'EOF'
cluster:
  network:
    cni:
      name: flannel
  proxy:
    disabled: false
EOF
for ip in 192.168.1.145 192.168.1.176 192.168.1.154 \
          192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233; do
  talosctl patch mc --mode=no-reboot --patch @/tmp/flannel-restore-patch.yaml --nodes "$ip" || break
done
talosctl --nodes 192.168.1.154 get manifests        # 05-flannel and 10-kube-proxy are back
```

```bash
# 2. Make Cilium clean up its CNI config when it goes away.
#    Git commit 1: set `cni.uninstall: true` in app/release.yaml, reconcile, wait for the agent rollout.
#    Git commit 2: remove `cilium/ks.yaml` and `cilium/routes-ks.yaml` from
#    k8s/infrastructure/kustomization.yaml.
#    `prune: true` on the cilium Kustomization means removing it UNINSTALLS the CNI
#    (helm uninstall). With cni.uninstall false that would leave 05-cilium.conflist
#    on every node and break pod creation; with true the agent's preStop hook
#    removes it.
flux reconcile source git flux-system
flux reconcile kustomization flux-system
kubectl -n kube-system get ds cilium                 # gone

# verify on every node: EXACTLY 10-flannel.conflist remains (present, NOT renamed),
# no 05-cilium.conflist and no *.cilium_bak
for ip in 192.168.1.145 192.168.1.176 192.168.1.154 \
          192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233; do
  echo "== $ip"; talosctl --nodes "$ip" ls /etc/cni/net.d
  talosctl --nodes "$ip" ls /etc/cni/net.d | grep -E '05-cilium|cilium_bak' && echo "LEFTOVER on $ip"
  talosctl --nodes "$ip" ls /etc/cni/net.d | grep -q '10-flannel.conflist$' || echo "MISSING 10-flannel.conflist on $ip"
done
```

If `05-cilium.conflist` or `*.cilium_bak` files are still there they must be
removed by hand: **a reboot does not clear them** (`/etc/cni` is a persistent
overlay on Talos) and `05-` sorts before `10-flannel.conflist`, so it would win.
If only `10-flannel.conflist.cilium_bak` exists, rename it back. `talosctl` has no
`rm`/`mv`; use a short-lived privileged pod with a `hostPath` mount of
`/etc/cni/net.d` pinned with `nodeName`, in `kube-system` (exempt from Talos'
default PodSecurity baseline; verify). Untested.

**Flannel host-local reservations (`/var/lib/cni/networks/cbr0`).** Flannel's CNI
plugin delegates to `host-local` IPAM, whose state is one file per allocated IP in
`/var/lib/cni/networks/cbr0` (verified live on `talos-hjl-umn`: `/var/lib/cni/networks/cbr0/10.244.6.*`, plus
`/var/lib/cni/flannel` and `results`). Pods torn down while Cilium was the CNI
never release their reservation, and `/var` persists across reboots on Talos. If
Flannel comes back with the same per-node /24, the leaked reservations stay
allocated and can exhaust the /24 over several migrations (host-local only reuses
an IP when its file is gone). **Before the §7.4 reboot of each node** (at that
moment only Cilium-managed pods run, so nothing legitimate uses the directory),
delete its contents with the same privileged `hostPath` pod pattern, mounting
`/var/lib/cni/networks` and running `rm -rf /host/cbr0`. Untested; the paths are
from the live node and the CNI `host-local` documentation.

```bash
# 3. Bring the Talos-rendered manifests (Flannel DaemonSet, kube-proxy) back.
#    `talosctl upgrade-k8s` re-applies the bootstrap manifests (server-side apply
#    with inventory); using the CURRENT Kubernetes version makes it a manifest sync.
#    Client must be >= v1.13 (checked in §1).
talosctl --nodes 192.168.1.154 upgrade-k8s --to 1.35.2 --dry-run
talosctl --nodes 192.168.1.154 upgrade-k8s --to 1.35.2
kubectl -n kube-system get ds kube-flannel kube-proxy
```

```bash
# 4. Rolling reboot of all nodes again with the §4 gates (adapt wait_node: the Cilium agent checks no
#    longer apply), host-local cleanup first, so every pod gets a Flannel IP.
#    Afterwards: git, re-gate the Kustomizations (suspend: true) if Cilium is re-added.
```

## 8. Follow-ups (separate commits/PRs)

- **WireGuard encryption:** set `encryption.enabled: true`,
  `encryption.type: wireguard`, `encryption.nodeEncryption: true` in
  `release.yaml` (commented placeholder already there).
- **Talos version convergence:** bring `talos-1i8-qm9` and `talos-i4x-2pd` from
  `v1.12.6` to `v1.13.0`. For Talos ≥ v1.14 the CNI/proxy settings move to the
  `KubeFlannelCNIConfig` / `KubeProxyConfig` documents (see §2); update this
  runbook then.
- **Payments HTTPRoute (`papi`).** The gateway/host move to `envoy-internal` /
  `papi.internal.grendel71.net` is done by a patch in `k8s/apps/payments/ks.yaml`.
  The patch silently does nothing if the payment-processor repo renames the route.
  Durable fix: set the internal gateway and host in
  <https://github.com/grendel71/payment-processor> `k8s/httproute.yaml` and drop
  the patch.
- **Cloudflare side of `papi` (intentionally NOT in this branch).** After the
  merge, the cloudflared wildcard still forwards `papi.grendel71.net` to
  `envoy-external`, which now answers 404 for it, and external-dns (sync policy)
  deletes the old `papi.grendel71.net` DNS record. Any Cloudflare/cloudflared
  change is a separate, manual step.
- **Phase 2, NetworkPolicy hardening:** audit the existing policies, fix the
  payments ingress selector (§1), add policies for `authentik`, `leaderboard`,
  `lifter`, `payments` and the `apps` namespace, a `cilium-policies` Kustomization
  that `dependsOn: cilium`, then set `policyEnforcementMode: default`.
- Re-evaluate `bpf.hostLegacyRouting` only if the Talos `forwardKubeDNSToHost`
  setting is turned off: eBPF host-routing requires `bpf.masquerade=true`
  (Cilium tuning guide), which the Talos guide lists as broken together with
  `forwardKubeDNSToHost`.

## 9. Executed migration (2026-11-16/17): what happened, and corrections

The window was run as written, except that the Velero backup (§1) was skipped on
purpose (an etcd snapshot was taken instead) and no rehearsal (§1a) was done.
Result: all 7 nodes on Cilium 1.20.4, Flannel and kube-proxy removed, no data lost,
`cilium-dbg status` shows `KubeProxyReplacement: True`, `Socket LB: Enabled`,
`Cluster health: 7/7`, 154/154 controllers healthy, all CNPG clusters healthy,
all four gateway VIPs answering.

Answers to the open §1a questions, from the real run:

- **(g) Does `Cluster health` reach N/N mid-window?** Yes. `wait_node` reported
  "cluster health full" for the rebooted workers and control planes while other
  nodes were still on the old network. The soft-check prompt never fired. Keep the
  prompt anyway: right after an agent starts, `Cluster health` can read `0/0`
  (observed on one worker) until the first probe round finishes.
- **(e) Helper greps match the real 1.20.4 output.** `KubeProxyReplacement: True`
  and `Socket LB: Enabled` matched on every node.
- **(a) The Flannel data path does not survive the agents starting.** Right after
  the Cilium DaemonSet rolled out, the §3 probe failed (100% ping loss, DNS timeout).
  The outage started at that moment, not at the first reboot. `cni.exclusive`
  renamed `10-flannel.conflist` to `10-flannel.conflist.cilium_bak` on every node
  and `05-cilium.conflist` appeared; `cni0` (`.1`) and `cilium_host` (a different
  `.N` in the same /24) coexisted without a collision on the node checked.
- The Cilium Helm install itself succeeded in seconds, `disableWait: true` was
  fine, and the rollout of 7 agents plus 2 operators took about 1 to 2 minutes.

Things that differed from the runbook, with the fix to apply next time:

1. **Check probe exit codes, not pipelines.** An ad hoc check piped the probe
   through `tail`, so a failed ping still printed "PROBE AFTER CILIUM OK". The
   `probe` function in §3 is correct; do not wrap it in a pipe. Read the output.
2. **Ceph mon failover.** While the network was split, Rook failed mon `c`
   (talos-i4x-2pd) over to a new mon `f` pinned to talos-xyn-p5v. `mon-f` sat
   `Pending` ("didn't satisfy existing pods anti-affinity", left over from the
   canary pod). Deleting the Pending pod let it schedule; quorum became `d,e,f`.
   Add to §5: if a mon pod is Pending after the last reboot, delete that pod
   before `osd unset noout`. `deploy/rook-ceph-mon-c` stays at 0 replicas. One OSD
   (`osd.5`) crashed once during the window and came back after its Error pod
   was deleted. `osd.2` (host `talos-uya-j6b`, which no longer exists) was down
   before the migration and is not related.
3. **CNPG hibernation is slow.** The 7 instance pods took about 3 to 4 minutes to
   terminate (graceful stop). Wait for `kubectl get pods -A -l cnpg.io/cluster`
   to be empty and for the RBD `VolumeAttachment`s to disappear (§2b gate).
   `immich-server` and the `bw-portal` worker mount NFS-backed PVCs, not RBD, so
   they do not need scaling for the attachment gate.
4. **The kube-vip holder moves.** It was `talos-cp-03` in the pre-checks and
   `talos-47z-ayo` just before the control-plane reboots, so the "reboot the
   holder last" order must be computed right before §4, not in §1. After the
   operator roll in the follow-up values change, the VIP also dropped for a few
   seconds once (a lease handover); retry before assuming a fault.
5. **Aborted loops.** If the worker loop is interrupted mid-reboot, do not restart
   it blindly. Check `uptime` (`talosctl read /proc/uptime`) and the bootID of each
   node, finish the interrupted node with the `wait_node` checks, then continue.
6. **`confirm` in the helpers** was replaced by an auto-yes because the whole
   window was pre-authorised. The etcd, VIP and kube-vip gates still ran before and
   after each control plane. Keep the interactive prompt when you run this by hand.
7. **HelmRelease picks up values late.** After merging a values change, the first
   `flux reconcile helmrelease cilium` still used the old values (the source
   artifact had not updated). Reconcile `source git`, then `kustomization
   flux-system`, wait until `kubectl -n kube-system get hr cilium -o
   jsonpath='{.spec.values}'` shows the new values, then reconcile the HelmRelease.
8. **Flux resume timeouts.** `flux resume kustomization arr` and `searxng`
   timed out at 2 minutes. They were resumed anyway; this is harmless.
9. **Leftover pod objects.** The reboots left about 58 `Failed`/`Error` pod objects.
   `kubectl delete pod -A --field-selector=status.phase=Failed` removes them. One
   runner pod (`runner-ghcr-*`) is held by an ARC `actions.summerwind.dev/runner-pod`
   finalizer and is not related.

Still true after the migration: `policyEnforcementMode` is `default` with
`policyAuditMode: true` (audit only, see `../cilium-policies/README.md` §5.2);
`bpf.hostLegacyRouting: true` stays; the migration-only `unmanagedPodWatcher`
override was removed (§6 done).
