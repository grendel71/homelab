# Cilium migration runbook (Flannel + kube-proxy → Cilium)

> Operator-only document. Flux ignores `.md`, so this folder is intentionally
> not kustomized. Nothing here is applied automatically — a human runs these
> steps from a shell with the dev shell active (`direnv allow` or `nix develop`).
> Run every command from the repo root.

**Goal:** replace the Talos-bootstrapped Flannel CNI and kube-proxy with Cilium
(kube-proxy replacement + Hubble), managed by Flux.

**State in git:** the `cilium` and `cilium-routes` Flux Kustomizations are
**GATED** (`suspend: true`). Merging the gated manifests to `main` installs
nothing. The cutover is a separate commit that sets `suspend: false` (step 3).
Do **not** use `flux resume`: the parent `flux-system` Kustomization re-applies
the files from git and reverts it.

---

## 0. Strategy and blast radius

**Declared maintenance window: cluster-wide pod-to-pod network outage between the
moment the first node switches CNI and the last node reboots (about 30–60 min).
Existing pods keep running on their old IPs until their node reboots. Expect
Flux, CNPG, Ceph clients and Envoy Gateway to be disrupted.**

Why: Flannel and Cilium would both own `10.244.0.0/16` (`ipam.mode: kubernetes`
reuses the node podCIDRs) and cannot interoperate. Flannel's overlay is VXLAN on
UDP 4789, Cilium's on UDP 8472, so nodes on different CNIs form two islands that
cannot reach each other's pods. Cilium's official zero-downtime migration
(<https://docs.cilium.io/en/stable/installation/k8s-install-migration/>) needs a
distinct pod CIDR plus `CiliumNodeConfig` and per-node rollout. We declined that
as too complex for this cluster.

What keeps working during the window (all host-network, independent of the CNI):
the Talos API, etcd, kube-apiserver, kubelet, KubePrism (`localhost:7445`, used
by Cilium and kubelet to reach the API), kube-vip (VIP `192.168.1.100`) and
MetalLB speakers. So `kubectl` and `talosctl` keep working throughout.

What does **not** work: anything pod-to-pod across islands. This includes **Ceph**
(mons and OSDs run on the pod network, so Ceph is degraded/blocked mid-window and
recovers once every node is on Cilium), CNPG replication/clients, Envoy proxies
reaching backends, Flux controllers reaching each other, CoreDNS from remote
pods. Pods get **new IPs** when their node reboots (new sandboxes).

Consequences for the procedure:

- Do everything that needs a working Flux/pod network **before** the first node
  switches (merge, reconcile, Hubble certs).
- Do not "wait for green" mid-window on anything that crosses the pod network.
  The strict Ceph gates apply **before the first reboot** and again in §5
  **before `osd unset noout`**.
- Keep the window short: reboot back-to-back once the old stack is deleted.

## 1. Pre-checks (all must pass before starting)

```bash
# every node Ready, versions as expected (2 CP + workers on 1.13.0, 1i8-qm9 and i4x-2pd on 1.12.6)
kubectl get nodes -o wide

# API reachable through the VIP, and who holds it (kube-vip leader)
kubectl --server https://192.168.1.100:6443 get --raw /readyz; echo
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'

# etcd: 3 members, none learner, no errors
talosctl --nodes 192.168.1.145,192.168.1.176,192.168.1.154 etcd status
talosctl --nodes 192.168.1.154 etcd members

# kube-vip healthy
kubectl -n kube-system get ds kube-vip-ds

# Ceph: HEALTH_OK, all PGs active+clean, mon quorum 3/3
kubectl rook-ceph ceph status
kubectl rook-ceph ceph osd tree

# Baselines to diff against after the migration (pre-existing failures are normal;
# at the time of writing: jellyfin/searxng Kustomizations, some Error/CrashLoop pods)
flux get kustomizations > /tmp/ks-before.txt
kubectl get pods -A | grep -vE 'Running|Completed' > /tmp/pods-before.txt
kubectl get clusters.postgresql.cnpg.io -A

# etcd snapshot, stored OUTSIDE the repo
mkdir -p ~/backups/etcd
talosctl --nodes 192.168.1.154 etcd snapshot ~/backups/etcd/pre-cilium-$(date +%Y%m%d-%H%M%S).db

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
  talosctl patch mc --mode=no-reboot --patch @/tmp/cilium-cni-patch.yaml --nodes "$ip"
done

# verify: on control planes 05-flannel and 10-kube-proxy must be gone from the rendered manifests
talosctl --nodes 192.168.1.154 get manifests
talosctl --nodes 192.168.1.154 get mc -o yaml | grep -nE 'name: none|disabled: true'
```

What this does: the patch is applied immediately, but it only changes the
**bootstrap manifests Talos renders**. **Nothing that already runs is deleted**:
the `kube-flannel` and `kube-proxy` DaemonSets, `flannel.1`, `cni0`, iptables
rules and `/etc/cni/net.d/10-flannel.conflist` all stay. Talos v1.13+ only prunes
rendered-away manifests when `talosctl upgrade-k8s` runs, so **do not run
`upgrade-k8s` during the window**. Its job is done by the deletions in step 3.
(After the migration a later `upgrade-k8s` finds nothing to prune.)

Leftovers: `flannel.1`, `cni0` and the old iptables rules disappear at reboot.
`/etc/cni` is **not** cleared by a reboot: on Talos it is an overlay persisted
under `/var/system/overlays/etc-cni-diff`. Cilium (`cni.exclusive: true`) renames
`10-flannel.conflist` to `10-flannel.conflist.cilium_bak` and writes
`05-cilium.conflist`; both persist (harmless while Cilium is the CNI, relevant for
rollback in §7).

**Talos version note.** Both patch forms above are for Talos < v1.14 (all nodes
here are 1.12.6 or 1.13.0). Talos ≥ v1.14 replaces them with
`KubeFlannelCNIConfig` (`$patch: delete`) and `KubeProxyConfig`
(`enabled: false`) documents (per
<https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium>).

**Local configs.** The git-ignored `talos-infra/` machine configs
(`controlplane.yaml`, `worker.yaml`, `workernvme.yaml`, `workernvidia.yaml`,
`controllaptop.yaml`, `controlmaster.yaml`) must get the same two keys by hand.
Otherwise a later `talosctl apply-config` re-introduces Flannel/kube-proxy.

## 3. Cutover (the window starts here)

**Order and why.**

1. `noout` first (Ceph must not rebalance while OSDs disappear).
2. Un-suspend Cilium and wait for all agents Ready. Cilium is installed and
   takes over each node's CNI config (`cni.exclusive`) while the old stack is
   still there, so nodes that have not rebooted yet keep as much of their old
   data path as possible (flanneld keeps its FDB, kube-proxy keeps syncing
   endpoints). Flux and the Helm install need the pod network, so this is the
   last moment they are reliable. Do not do anything else slow after it.
3. Delete Flannel and kube-proxy **before the first reboot**. Otherwise the
   DaemonSets start again on every rebooted node, rewrite the Flannel CNI config
   and install kube-proxy iptables next to Cilium. Neither flanneld nor
   kube-proxy is expected to clean up its links/rules when its pod stops, so
   deleting the DaemonSets should not cause the outage by itself (leftovers go at
   reboot; this was not tested on this cluster).
4. Reboot all nodes one by one (§4): workers first, control planes last.

```bash
# 1. Ceph: do not mark OSDs out while they are unreachable
kubectl rook-ceph ceph osd set noout
```

```bash
# 2. Cutover commit: suspend: false on cilium and cilium-routes (NOT flux resume)
sed -i 's/^  suspend: true # GATED.*/  suspend: false # CUTOVER done, see MIGRATION.md/' \
  k8s/infrastructure/cilium/ks.yaml k8s/infrastructure/cilium/routes-ks.yaml
git diff --stat
git commit -am "feat(cilium): cutover, un-suspend cilium Kustomizations"
# merge to main (PR), then:
flux reconcile source git flux-system
flux reconcile kustomization flux-system
flux reconcile kustomization cilium

kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m
kubectl -n kube-system get pods -l k8s-app=cilium -o wide        # 7 pods Running, one per node
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Cluster health'
```

If `flux get hr -n kube-system cilium` shows a failed release, **do not uninstall
or roll back** (remediation is disabled on purpose, `retries: 0`).
Read `kubectl -n kube-system describe hr cilium`, fix the cause, and after the window
force a retry with `flux reconcile helmrelease cilium -n kube-system --force`.
The Hubble relay/UI pods may only become Ready after reboots; that is the
usual reason for a timed-out release during the window.

```bash
# 3. Remove Flannel + kube-proxy: exactly what Talos rendered (see `talosctl get manifests` before the patch)
kubectl -n kube-system delete ds kube-proxy kube-flannel
kubectl -n kube-system delete sa kube-proxy flannel
kubectl -n kube-system delete cm kube-flannel-cfg
kubectl delete clusterrolebinding kube-proxy flannel
kubectl delete clusterrole flannel
```

Never delete `kube-vip-ds` or the `metallb` speaker DaemonSet.

## 4. Rolling reboot with gates (workers first, then control planes)

Never reboot two nodes at once. Paste the helpers once:

```bash
WORKERS="192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233"

# node name for an InternalIP
node_name() {
  kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$1" '$2==ip{print $1}'
}

# after a reboot: kubelet Ready, Cilium agent Ready on that node, KPR on
wait_node() {
  local n; n=$(node_name "$1")
  kubectl wait --for=condition=Ready "node/$n" --timeout=600s
  kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$n" --timeout=600s
  kubectl -n kube-system exec "$(kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$n" -o name)" -c cilium-agent -- \
    cilium-dbg status | grep -E 'KubeProxyReplacement|Cluster health'
}

# control-plane gate: etcd 3 healthy members, kube-vip healthy, VIP answers
cp_gate() {
  talosctl --nodes 192.168.1.145,192.168.1.176,192.168.1.154 etcd status
  kubectl -n kube-system get ds kube-vip-ds
  kubectl --server https://192.168.1.100:6443 get --raw /readyz; echo
}
```

**Workers.** Gate before the **first** worker (strict baseline; stop if it fails):

```bash
kubectl rook-ceph ceph status   # HEALTH_OK except the noout warning, all PGs active+clean, mon quorum 3/3
```

Between later workers Ceph is **expected to be degraded** (the rebooted workers'
OSDs sit on the Cilium island, the mons may still be on the Flannel island), so
`ceph status` can hang or show down OSDs and inactive PGs. That is not a reason
to stop. The gate for each following worker is: the previous node passed
`wait_node`, and its pods are Running (`kubectl get pods -A -o wide | grep <node>`).
Never run `osd out`, `osd purge` or `osd unset noout` in the window.

```bash
for ip in $WORKERS; do
  echo "== rebooting worker $ip ($(node_name $ip)) =="
  talosctl reboot --nodes "$ip"      # waits until the node is back
  wait_node "$ip" || break           # stop on the first failure, investigate
done
```

**Control planes.** Reboot the current kube-vip holder **last** (it holds
`plndr-cp-lock`; rebooting it forces a VIP failover). kube-vip reaches the API
through the `10.96.0.1` ClusterIP, which now depends on Cilium instead of
kube-proxy, so `cp_gate` also verifies kube-vip after each reboot. Before **each**
control-plane reboot `cp_gate` must show: 3 etcd members without errors,
`kube-vip-ds` 3/3 ready, and the VIP answering `ok`.

```bash
HOLDER=$(kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'); echo "VIP holder: $HOLDER"
# default order: 1i8-qm9 (.145), 47z-ayo (.176), then the holder talos-cp-03 (.154)
# if the holder is NOT talos-cp-03, put the holder's IP last.
for ip in 192.168.1.145 192.168.1.176 192.168.1.154; do
  echo "== control-plane $ip ($(node_name $ip)): gate =="
  cp_gate || break
  talosctl reboot --nodes "$ip"
  wait_node "$ip" || break
  cp_gate || break                   # etcd back to 3 healthy, kube-vip 3/3, VIP ok
done
```

If etcd shows fewer than 3 healthy members after a control-plane reboot, wait for
it to rejoin (`talosctl etcd members`); do not reboot the next control plane.

## 5. Post-checks

```bash
# Cilium healthy on every node, KPR active, no flannel/kube-proxy left
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Cluster health|Controller Status'
kubectl get ds -A | grep -E 'flannel|kube-proxy' || echo clean
kubectl get nodes -o wide

# control plane + VIP
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

# Ceph: full recovery BEFORE removing noout
kubectl rook-ceph ceph status                   # HEALTH_OK except noout, PGs active+clean, mon quorum 3/3
kubectl rook-ceph ceph osd tree
kubectl rook-ceph ceph osd unset noout          # re-enables marking down OSDs "out" (not backfill)
kubectl rook-ceph ceph status                   # HEALTH_OK

# CNPG clusters healthy
kubectl get clusters.postgresql.cnpg.io -A

# Flux: every Kustomization Ready (compare with the baseline)
flux get kustomizations > /tmp/ks-after.txt; diff /tmp/ks-before.txt /tmp/ks-after.txt
flux get kustomizations | grep -v True || echo "all Ready"
flux get helmreleases -A | grep -v True || echo "all Ready"
kubectl get pods -A | grep -vE 'Running|Completed' | diff /tmp/pods-before.txt - || true

# optional: needs the cilium CLI and a privileged test namespace (Talos PodSecurity)
# cilium connectivity test
```

## 6. After success: follow-up commit

A **separate** commit after §5 passes:

- Delete the `operator.unmanagedPodWatcher` block from `app/release.yaml`
  (restores the default `restart: true`: the operator restarts pods that are not
  managed by Cilium).
- Leave `bpf.hostLegacyRouting: true` and `policyEnforcementMode: never`
  untouched here. `policyEnforcementMode` becomes `default` **only in the Phase 2
  commit**, together with the audited/verified policies (including the payments
  selector fix from §1).

## 7. Rollback

**Never run `talosctl bootstrap`.** It initialises etcd and is dangerous on a live
cluster; it is not a way to bring back Flannel.

- **Before the cutover commit:** nothing to roll back. The Kustomizations are
  suspended, nothing is installed. Revert the gate PR if wanted.
- **After the cutover commit:** pods that have already moved to Cilium stay
  there. Going back to Flannel after nodes have rebooted onto Cilium is a
  **second maintenance window**.

Steps:

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
  talosctl patch mc --mode=no-reboot --patch @/tmp/flannel-restore-patch.yaml --nodes "$ip"
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

# check every node: only 10-flannel.conflist may remain, no 05-cilium.conflist
for ip in 192.168.1.145 192.168.1.176 192.168.1.154 \
          192.168.1.103 192.168.1.215 192.168.1.144 192.168.1.233; do
  talosctl --nodes "$ip" list /etc/cni/net.d
done
```

If `05-cilium.conflist` or `*.cilium_bak` files are still there they must be
removed by hand: **a reboot does not clear them** (`/etc/cni` is a persistent
overlay on Talos) and `05-` sorts before `10-flannel.conflist`, so it would win.
`talosctl` has no `rm`; use a privileged hostNetwork pod with a `hostPath` mount of
`/etc/cni/net.d`, and rename any `*.cilium_bak` back.

```bash
# 3. Bring the Talos-rendered manifests (Flannel DaemonSet, kube-proxy) back.
#    `talosctl upgrade-k8s` re-applies the bootstrap manifests (server-side apply
#    with inventory); using the CURRENT Kubernetes version makes it a manifest sync.
talosctl --nodes 192.168.1.154 upgrade-k8s --to 1.35.2 --dry-run
talosctl --nodes 192.168.1.154 upgrade-k8s --to 1.35.2
kubectl -n kube-system get ds kube-flannel kube-proxy
```

```bash
# 4. Rolling reboot of all nodes again with the §4 gates, so every pod gets a Flannel IP.
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
- **Phase 2, NetworkPolicy hardening:** audit the existing policies, fix the
  payments ingress selector (§1), add policies for `authentik`, `leaderboard`,
  `lifter`, `payments` and the `apps` namespace, a `cilium-policies` Kustomization
  that `dependsOn: cilium`, then set `policyEnforcementMode: default`.
- Re-evaluate `bpf.hostLegacyRouting` only if Talos `forwardKubeDNSToHost` is
  turned off.
