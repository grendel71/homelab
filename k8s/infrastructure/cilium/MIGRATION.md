# Cilium migration runbook (Flannel + kube-proxy → Cilium)

> Operator-only document. Flux ignores `.md`, so this folder is intentionally
> not kustomized. Nothing here is applied automatically — a human runs these
> steps from a shell with `nix develop` active (`direnv allow` or `nix develop`).

**Goal:** replace the Talos-bootstrapped Flannel CNI and kube-proxy with Cilium
(kube-proxy replacement + Hubble), managed by Flux. Cilium reuses the existing
`10.244.0.0/16` per-node podCIDRs (`ipam.mode: kubernetes`), so **pod IPs do not
change** and no workload rescheduling is required by IPAM.

**Expected downtime:** brief, node-local pod-network blips during the mixed-CNI
window and the rolling reboot. Control-plane API stays up via kube-vip.

**Mixed Talos versions:** 2 nodes run `v1.12.6` (`talos-1i8-qm9` control-plane,
`talos-i4x-2pd` worker), 5 run `v1.13.0`. Both are < v1.14, so the classic
`cluster.network.cni.name` / `cluster.proxy.disabled` machine-config patch below
applies unchanged to every node. (Talos ≥ v1.14 would need the
`KubeFlannelCNIConfig` / `KubeProxyConfig` delete-style patches instead.)

---

## 0. Safety notes

- **kube-vip VIP `192.168.1.100` is untouched.** The node `nodeIP`/etcd
  `advertisedSubnets` exclusions for that VIP are unaffected by Cilium — Cilium
  does not manage the control-plane VIP (kube-vip does) and does not take over
  Service load-balancing (MetalLB stays). `kube-vip-ds` (DaemonSet in
  `kube-system`) and `metallb-speaker` (DaemonSet in `metallb-system`) **must not
  be deleted**.
- Cilium coexists with MetalLB L2 and kube-vip: it only installs its CNI
  datapath, `cilium-operator`, and Hubble. No L2 announcements, no LB-IPAM, no
  BGP, no Gateway API/Ingress controller (Envoy Gateway stays).

## 1. Pre-checks (all must pass before starting)

```bash
# every node Ready, and versions as expected
kubectl get nodes -o wide

# control-plane API reachable through the VIP
kubectl get --raw /readyz && echo OK

# etcd healthy
talosctl etcd status
talosctl get members

# Ceph HEALTH_OK and all PGs active+clean (workers run the OSDs)
kubectl rook-ceph ceph status
kubectl rook-ceph ceph osd tree

# Envoy Gateway / MetalLB healthy (post-check baseline)
kubectl -n envoy-gateway-system get deploy,svc
kubectl -n metallb-system get pods

# fresh etcd snapshot (store OUTSIDE the repo; etcd-*.db is git-ignored)
talosctl etcd snapshot ./etcd-pre-cilium-$(date +%Y%m%d-%H%M%S).db

# Velero backup completes
velero backup create pre-cilium --wait
velero backup get
```

**NetworkPolicy warning — read carefully.** The following NetworkPolicies
already exist and are currently **NOT enforced** (Flannel has no NetworkPolicy
enforcement). Cilium enforces them the moment it starts managing endpoints:

```bash
kubectl get netpol -A
```

| Namespace | NetworkPolicy | Selector |
|---|---|---|
| flux-system | allow-egress | (empty) |
| flux-system | allow-scraping | (empty) |
| flux-system | allow-webhooks | app=notification-controller |
| payments | payments-platform | app.kubernetes.io/name=payments-platform |
| payments | payments-platform-migrate | app.kubernetes.io/component=migration |

Review them before starting. If any denies a flow the workload needs, the pod
will break after Cilium takes over. The policy baseline/audit is handled in a
later phase; for this migration, the key check is that **Flux itself and
payments keep working** after enforcement begins (watch `flux get kustomizations`
and the payments pods). Note `policyEnforcementMode: default` means only pods
*selected* by a policy are restricted — everything else stays open.

## 2. Patch Talos machine configs (all 7 nodes)

Create the patch file:

```yaml
# cilium-cni-patch.yaml
cluster:
  network:
    cni:
      name: none      # stop bootstrapping Flannel
  proxy:
    disabled: true    # stop bootstrapping kube-proxy
```

Apply to **every node** with `--mode=no-reboot` (this does not reboot; it only
updates the machine config):

```bash
# one at a time, or use the default node list the flake shellHook sets
for ip in 192.168.1.145 192.168.1.176 192.168.1.154 \
          192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233; do
  talosctl patch mc --mode=no-reboot --patch @cilium-cni-patch.yaml --nodes "$ip"
done

# verify (optional): the patch is recorded, not yet applied to running state
talosctl get mc -o json | grep -E '"name": "none"|"disabled": true'
```

> **Important:** this patch only changes what Talos writes at *bootstrap time*.
> The already-running `kube-flannel` and `kube-proxy` DaemonSets stay until you
> delete them in step 4. It also does **not** apply the change to the running
> node — the effective handover happens at the reboot in step 5.
>
> **Local configs:** the per-node-type machine configs live in the git-ignored
> `talos-infra/` directory (`controlplane.yaml`, `worker.yaml`, `workernvme.yaml`,
> `workernvidia.yaml`, …). Add the same two keys there so a future
> `talosctl apply-config` or re-provision does not reintroduce Flannel/kube-proxy.

## 3. Install Cilium via Flux

Cilium is fully GitOps-managed by this branch (`k8s/infrastructure/cilium/`):

1. Merge the branch (or open the PR) so Flux syncs the new manifests.
2. Confirm the HelmRepository, Kustomizations, and HelmRelease are healthy:

```bash
flux get sources helm -A | grep cilium
flux get kustomizations
flux get helmrelease -n kube-system cilium
```

3. Wait for the Cilium DaemonSet and operator to be Ready:

```bash
kubectl -n kube-system get ds cilium -o wide
kubectl -n kube-system get deploy cilium-operator
kubectl -n kube-system rollout status ds/cilium --timeout=10m
```

4. Confirm Cilium is running alongside (still) Flannel and kube-proxy:

```bash
kubectl -n kube-system get ds | grep -E 'cilium|flannel|proxy'
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
```

At this point Cilium is up but **not yet the active CNI** on every node — the
nodes still run Flannel until you complete steps 4–5.

## 4. Delete Flannel + kube-proxy (and leftovers)

```bash
# stop kube-proxy first (Cilium is already doing kube-proxy replacement)
kubectl -n kube-system delete ds kube-proxy

# then flannel
kubectl -n kube-system delete ds kube-flannel

# flannel leftovers (ConfigMap + RBAC)
kubectl -n kube-system delete cm kube-flannel-cfg
kubectl -n kube-system delete sa flannel
kubectl delete clusterrole flannel
kubectl delete clusterrolebinding flannel
```

> The `cilium-agent` pod writes its own CNI config (`/etc/cni/net.d/…`) and
> removes the stale Flannel CNI config on each node. Until each node is rebooted
> in step 5, some nodes may briefly be in a mixed state — this is the expected
> short pod-network outage window. Pods that lose connectivity are rescheduled;
> the reboot below makes the handover clean per-node.

## 5. Rolling reboot — workers first, then control planes (one at a time)

Do **not** reboot more than one node at a time. Keep etcd quorum (2 of 3
control-plane nodes up) and keep the kube-vip VIP live at all times.

```bash
# 1. Cordon Ceph from reboots so OSDs drain cleanly (workers host OSDs)
kubectl rook-ceph ceph osd set noout
# (also fine to set nobackfill/norecover during the window, but noout is the key one)
```

Reboot **workers** first, one at a time, verifying between each:

```bash
# worker order (workers only)
for ip in 192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233; do
  echo "== rebooting worker $ip =="
  talosctl reboot --nodes "$ip" --wait
  kubectl wait --for=condition=Ready node/$(kubectl get nodes -o jsonpath="{.items[?(@.status.addresses[?(@.address=='$ip')].address)].metadata.name}") --timeout=300s
  kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E 'Node|Healthy|Containers|KubeProxy'
  # spot-check cross-node connectivity before the next node
  kubectl get pods -A -o wide | grep -v Running || true
done
```

Then reboot **control planes**, one at a time, keeping quorum:

```bash
# control-plane order (2 members stay up while 1 reboots)
for ip in 192.168.1.154 192.168.1.176 192.168.1.145; do
  echo "== rebooting control-plane $ip =="
  talosctl reboot --nodes "$ip" --wait
  kubectl wait --for=condition=Ready node/$(kubectl get nodes -o jsonpath="{.items[?(@.status.addresses[?(@.address=='$ip')].address)].metadata.name}") --timeout=300s
  # etcd quorum + API through VIP must stay healthy
  talosctl get members
  kubectl get --raw /readyz && echo API-OK
done

# 2. Re-enable Ceph backfill once every node is done
kubectl rook-ceph ceph osd unset noout
```

**Verification during the window:**

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
# expect: all nodes listed, KubeProxyReplacement=Strict/True, no "no cni" errors
kubectl get nodes -o wide   # all Ready
kubectl get pods -A | grep -v Running   # nothing stuck CrashLoop/ContainerCreating
```

## 6. Post-checks

```bash
# Cilium healthy on every node, kube-proxy replacement active
kubectl -n kube-system exec ds/cilium -- cilium-dbg status

# no flannel/kube-proxy left anywhere
kubectl get ds -A | grep -E 'flannel|proxy' || echo "clean"

# control plane + VIP
kubectl get --raw /readyz && echo API-OK
kubectl get svc kubernetes   # ClusterIP 10.96.0.1 reachable

# Envoy Gateway + MetalLB VIPs still reachable (192.168.1.69/.70/.71/.72)
kubectl -n envoy-gateway-system get pods
kubectl -n envoy-gateway-system get svc envoy-envoy-gateway-class -o jsonpath='{.status.loadBalancer.ingress}'; echo
curl -sk https://hubble.internal.grendel71.net/ | head -c 200; echo

# DNS (CoreDNS must resolve inside the cluster)
kubectl -n kube-system get pods | grep coredns
kubectl run dnscheck --rm -it --restart=Never --image=busybox -- nslookup kubernetes.default

# Ceph + CNPG
kubectl rook-ceph ceph status
kubectl get clusters.postgresql.cnpg.io -A   # or per-app CNPG clusters Ready

# Hubble UI is served through envoy-internal (not public)
curl -sk https://hubble.internal.grendel71.net/ | head -c 200; echo

# optional: full connectivity test (needs cilium CLI; note Talos PodSecurity
# may require `--force-deploy` or a privileged namespace label for the test pods)
# cilium connectivity test
```

## 7. Rollback (if Cilium must be removed before cutover is complete)

**Before deleting Flannel (steps 4–5):** rollback is a pure Flux operation —
revert/merge the branch removal and `flux reconcile kustomization flux-system`;
Flannel + kube-proxy were never touched and remain active.

**After Flannel is deleted but before the reboot completes:**

```bash
# re-apply the Talos bootstrap CNI/proxy (reverts the step-2 patch)
#   cluster.network.cni.name: flannel   cluster.proxy.disabled: false
# re-create flannel + kube-proxy by re-running bootstrap on a control-plane:
talosctl bootstrap --nodes 192.168.1.145   # re-applies bootstrap manifests
# then revert the Flux change and reconcile
```

**After full cutover (post step 5):** rolling back means re-introducing
Flannel+kube-proxy. Reverse steps: revert the Talos patch (cni back to `flannel`,
`proxy.disabled: false`), `talosctl bootstrap`, delete the Cilium HelmRelease via
Flux (remove the Kustomization), then rolling-reboot again. Pod IPs stay the same
(ipam.mode was `kubernetes`), so workloads keep their addresses.

## 8. Follow-ups (separate PRs)

- **WireGuard encryption** — set `encryption.enabled: true`,
  `encryption.type: wireguard`, `encryption.nodeEncryption: true` in
  `release.yaml` (commented placeholder is already in the values).
- **Talos version convergence** — bring `talos-1i8-qm9` and `talos-i4x-2pd` from
  `v1.12.6` up to `v1.13.0` so all nodes match, then consider v1.14+ (which
  changes the CNI/proxy patch format — update this runbook when you do).
- **NetworkPolicy hardening (Phase 2)** — the `cilium-policies` +
  per-namespace policies for `payments`, `authentik`, `leaderboard`, `lifter`,
  and the `jellyfin`/`website` pods in `apps` (see plan tasks 3–4).
