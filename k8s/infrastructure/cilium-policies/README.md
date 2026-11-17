# cilium-policies (Phase 2: network policy for public-facing workloads)

> Operator documentation. Flux ignores `.md`; this file is not part of any
> kustomization. Run commands from the repo root inside the dev shell
> (`direnv allow` / `nix develop`).

**State in git:** the `cilium-policies` Flux Kustomization (`ks.yaml`) has
`dependsOn: [cilium, namespace]`. `cilium` is `suspend: true`, so this
Kustomization stays blocked until the Cilium cutover (see
`../cilium/MIGRATION.md`). Even after it applies, the Cilium HelmRelease sets
`policyEnforcementMode: never`, so **no policy (CiliumNetworkPolicy or
Kubernetes NetworkPolicy) is enforced** until the commit described in
[Enabling enforcement](#5-enabling-enforcement).

The gate is **only** `dependsOn: cilium` (plus the suspended Kustomization it
points to). Removing that `dependsOn` entry un-gates this Kustomization and
Flux would apply the CNPs before Cilium (and its CRD) exists, which fails with
"no matches for kind". Do not remove it.

Note: the gateway IPs in the repo-root `AGENTS.md` are stale. Live
(`kubectl get svc -A | grep LoadBalancer`, checked read-only): envoy-external
`192.168.1.67`, traefik-internal `192.168.1.68`, envoy-internal
`192.168.1.69`, envoy-nx `192.168.1.71`, tcp-gateway `192.168.1.72` (AGENTS.md
says `.69` external / `.70` internal).

Layout:

| Path | Purpose |
|---|---|
| `ks.yaml` | Flux Kustomization, gated by `dependsOn: cilium` |
| `app/kustomization.yaml` | lists the policy files |
| `app/<workload>.yaml` | `CiliumNetworkPolicy` resources, one file per workload |

## 1. Audit of the existing NetworkPolicies

`kubectl get netpol -A` (read-only, live) shows 5 policies: 3 in `flux-system`
(from `k8s/flux-system/gotk-components.yaml`) and 2 in `payments` (rendered by
the upstream `payments-platform` Helm chart 0.2.4, from
<https://github.com/grendel71/payment-processor>, `k8s/release.yaml` values +
`payments-platform/templates/networkpolicy.yaml`).

How Cilium (v1.20.4) translates them (checked against
`pkg/k8s/network_policy.go`):

- an egress or ingress rule with no `to`/`from` is a wildcard (matches every
  identity, including `world` and `host`);
- `podSelector` without `namespaceSelector` is scoped to the policy's own
  namespace;
- `namespaceSelector: {}` means "any pod in any namespace". It matches **pods
  only**, not the node (`host` / `remote-node`) or the outside world;
- Cilium NetworkPolicy and Kubernetes NetworkPolicy allows are additive (union).

Cilium always allows the local node to reach local pods (`allow-localhost`,
default `auto`), so kubelet liveness/readiness probes never need a rule.
Reply traffic of an allowed connection is allowed implicitly.

### flux-system (3 policies, all fine, no compensating policy needed)

Live pods (all `app=<controller>`): helm-controller, kustomize-controller,
source-controller, notification-controller, image-automation-controller,
image-reflector-controller. Services: `source-controller:80`,
`notification-controller:80`, `webhook-receiver:80`.

| Policy | Selects | Allows | Verdict |
|---|---|---|---|
| `allow-egress` | all pods | Egress: **everything** (`- {}`). Ingress: from any pod in `flux-system`. | OK |
| `allow-scraping` | all pods | Ingress: TCP 8080 from any pod in any namespace (metrics). | OK |
| `allow-webhooks` | `app=notification-controller` | Ingress: any port from any pod in any namespace. | OK |

What this means once enforced, for the flows asked about:

- **Flux controllers -> kube-apiserver, git hosts (GitHub), Helm/OCI
  registries, Cloudflare/SOPS endpoints:** allowed, `allow-egress` is a
  wildcard egress (includes `host`/`remote-node` for the API server on the
  control-plane nodes, `world` for GitHub/registries).
- **Controllers -> each other, notably kustomize/helm/image-automation ->
  source-controller (artifact server, port 9090 behind Service `:80`):**
  allowed, same namespace (`allow-egress` ingress rule `from: podSelector: {}`).
- **Notification webhooks (`webhook-receiver` Service, receiver on 9292):**
  `allow-webhooks` admits any pod. The Envoy proxy pods are pods in
  `envoy-gateway-system`, so they match `namespaceSelector: {}`.
- **kubelet probes:** the local node is always allowed (`allow-localhost`).
- **In-cluster Services of the Flux controllers stay reachable:** the only
  clients are pods (same namespace or Envoy), covered above. Flux has no
  admission webhook that the API server would call (that would be the one
  `host`/`remote-node` -> pod flow these policies would break).
- Prometheus scraping on 8080: allowed from any namespace; there is no
  Prometheus in this cluster at present.

Nothing breaks, so **no compensating CiliumNetworkPolicy is added for
`flux-system`**, and no policy in this repo selects pods in `flux-system`.

### payments (2 policies)

Live pods: `payments-platform-*` (2 Running, labels
`app.kubernetes.io/name=payments-platform`,
`app.kubernetes.io/instance=payments-platform`), `payments-db-1` (CNPG,
`cnpg.io/cluster=payments-db`). The HelmRelease values come from the external
repo (`k8s/release.yaml`, `networkPolicy.enabled: true`), so this repo cannot
edit them.

| Policy | Selects | Ingress | Egress | Verdict |
|---|---|---|---|---|
| `payments-platform` | `name=payments-platform,instance=payments-platform` | TCP 8000 from pods in `envoy-gateway-system` labelled `app.kubernetes.io/name=envoy-gateway` | DNS (UDP/TCP 53) to `k8s-app=kube-dns` in `kube-system`; TCP 5432 to `cnpg.io/cluster=payments-db` in `payments` | **BREAKS the workload** |
| `payments-platform-migrate` | `component=migration,name=payments-platform-migration,instance=payments-platform` | not restricted (policyTypes: Egress) | same DNS + DB 5432 as above | OK |

Why `payments-platform` breaks: no pod carries
`app.kubernetes.io/name=envoy-gateway` (live check:
`kubectl -n envoy-gateway-system get pods --show-labels`). The Envoy Gateway
controller is `app.kubernetes.io/name=gateway-helm` and the data-plane proxy
pods are `app.kubernetes.io/name=envoy` + `component=proxy` +
`gateway.envoyproxy.io/owning-gateway-name=<gateway>`. Because the policy also
lists `Ingress` in `policyTypes`, enforcing it would drop **all** ingress to the
payments API.

Egress is correct: the app only needs its database (the chart reads
`DATABASE_URL` from a Secret via `secretKeyRef`; `serviceAccount.automount:
false`, so no API-server access; no outbound HTTP in `app/`). The migration Job
needs only DNS + DB, which its policy gives.

**Compensating policy: yes** (`app/payments.yaml`). It adds the missing allow
from the real Envoy proxy pods to `payments-platform` on 8000 (additive with the
broken upstream policy, which then simply matches nothing), repeats the DNS/DB
egress so egress default-deny does not depend on the upstream chart, and adds
the ingress policy for the `payments-db` CNPG pods (migration Job and app may
connect, operator may manage). The upstream policy is left alone (it is not in
this repo).

Gateway state of the payments route: the live HTTPRoute
`payments-platform-internal` (`papi.grendel71.net`) is **still on
`envoy-external`**. The commit that moves it to `envoy-internal` (`2ecd14d`,
patch in `k8s/apps/payments/ks.yaml`) exists only on the `feat/cilium-hardening`
branch and is not on `main` yet. The compensating allow therefore admits both
gateways, which is correct before and after that merge. Once the route is live
on `envoy-internal` only, `envoy-external` can be dropped from the allow in
`app/payments.yaml`.

Follow-up (outside this repo): fix the upstream chart values
(`networkPolicy.ingress.podSelector: {app.kubernetes.io/name: envoy,
app.kubernetes.io/component: proxy}`), after which the compensating allow is
redundant but harmless.

### Other namespaces

`kubectl get netpol -A` returns nothing for any other namespace. Flannel never
enforced policies, so nothing else was ever relied on; **all other namespaces
stay default-allow** (no policy selects them).

## 2. Design rules

- **Ingress** to every selected workload is default-deny (a CNP with an
  `ingress` rule selecting a pod does that). Allows: the Envoy **proxy** pods
  only (`k8s:io.kubernetes.pod.namespace=envoy-gateway-system`,
  `app.kubernetes.io/name=envoy`, `app.kubernetes.io/component=proxy`, and
  `gateway.envoyproxy.io/owning-gateway-name=envoy-external`; payments allows
  `envoy-internal` and `envoy-external`), on the container port only.
  The Envoy Gateway controller (`name=gateway-helm`) is not a traffic path and
  is not allowed.
  Debugging note: ingress default-deny drops **all** unlisted traffic to the
  selected pods, ICMP included (e.g. `ping` / ICMP-based checks from another
  pod to a selected pod will fail), not only TCP on unlisted ports.
- **Probes:** never need a rule (local `host` is always allowed by Cilium).
  No `host` rule is added anywhere.
- **Databases:** every selected app has its own CNPG cluster. Each DB pod
  (`cnpg.io/cluster=<name>`, `cnpg.io/podRole=instance`, which excludes initdb
  Jobs) accepts: its app pod(s) on 5432; the CNPG operator
  (`cnpg-system`, `app.kubernetes.io/name=cloudnative-pg`) on 8000 + 5432;
  pods of the same cluster on 5432 + 8000. DB **egress is not restricted**
  (instance manager -> API server, replication, future backups).
- **Egress** is restricted only where it is provable:
  - `payments-platform`, `website`: exact allow-list (DNS + the one upstream).
    No `toFQDNs` rule exists anywhere, so DNS is a plain port-53 allow to
    `k8s-app=kube-dns` and the Cilium DNS proxy (`rules.dns`) is deliberately
    not engaged. **A future `toFQDNs` rule must add `rules.dns:
    [{matchPattern: "*"}]` on the DNS rule.**
  - `lifter`: LAN/nodes denied, everything else open (see below).
  - `authentik`, `jellyfin`: egress left **open** (destinations are configured
    at runtime in the app, not in git).
- **Prometheus:** none exists in the cluster (no monitoring namespace, no
  `monitoring.coreos.com` CRDs), so no scrape allow is added. Metrics ports
  (authentik 9300, CNPG 9187) stay closed.
- **No policy selects** pods in `kube-system`, `rook-ceph`, `flux-system`,
  `cnpg-system`, `metallb-system`, `envoy-gateway-system`, `cilium`, nor any
  other pod in `apps` than jellyfin and website.
- **LAN/node/internal-proxy deny** (`lifter-egress-deny-lan`): `egressDeny` to `192.168.0.0/16`, entities `host`
  and `remote-node`, and the internal reverse-proxy pods (below), with
  `enableDefaultDeny.egress: false`.
  - **Why proxy pods are listed.** With kube-proxy replacement Cilium
    translates a Service frontend (ClusterIP, NodePort, MetalLB LoadBalancer
    VIP) to a backend **before** policy is evaluated, so policy sees the
    backend pod identity, never the VIP. A CIDR deny on `192.168.0.0/16`
    therefore does not stop a pod from reaching `192.168.1.69` (envoy-internal),
    whose backend is a pod. The deny is expressed on the proxy pods instead:
    Envoy proxies in `envoy-gateway-system` with
    `app.kubernetes.io/name=envoy`, `app.kubernetes.io/component=proxy` and
    `gateway.envoyproxy.io/owning-gateway-name` in (`envoy-internal`,
    `envoy-nx`, `tcp-gateway`) (live: 1 Running pod each, 3 total), and the
    traefik-internal pods (`namespace=traefik-internal`,
    `app.kubernetes.io/name=traefik`,
    `app.kubernetes.io/instance=traefik-internal-traefik-internal`, live: 1
    Running pod). `envoy-external` is **not** denied: it is these apps' own
    public path, and nothing in their manifests calls a hostname.
  - **What is blocked:** direct LAN/node IPs (including node IPs used as
    NodePort targets and the kube-apiserver on control-plane nodes + VIP
    `.100`), the internal admin UIs behind `envoy-internal` (router, pve,
    truenas, dns, s3, rook, hubble, *arr, ...), `envoy-nx` (`*.x.nx8192.win`),
    `tcp-gateway` and `traefik-internal`, and Services whose backends are LAN
    IPs (e.g. the selectorless `kube-system` Services `pve` / `pve2`).
  - **Residual paths, not blocked:** every other pod reachable through a
    ClusterIP Service or pod IP (`10.244.0.0/16`, `10.96.0.0/12`), i.e. other
    in-cluster apps and admin UIs. This is not in-cluster segmentation. A new
    internal gateway or proxy added later is **not** covered until it is added
    to the deny list in `app/lifter.yaml`.

  The `enableDefaultDeny.egress: false` field is mandatory: with the
  chart default `enableNonDefaultDenyPolicies: true`, a policy that has only
  `egressDeny` would otherwise put the pods in egress default-deny and drop
  all egress. Before enforcement, check the rendered config:
  `kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-non-default-deny-policies}'`
  must print `true` (the chart default; `release.yaml` does not override it).

## 3. Policy table

Live pod counts are Running pods matched by the selector (read-only
`kubectl get pods -n <ns> -l <selector> --field-selector=status.phase=Running`).

| Policy (CNP) | Namespace | Selected pods (live) | Allowed ingress | Allowed egress | Evidence |
|---|---|---|---|---|---|
| `payments-platform-ingress` | payments | `name=payments-platform,instance=payments-platform` (2) | Envoy proxies (`envoy-internal`, `envoy-external`) TCP 8000 (live route still on external; move commit `2ecd14d` is not on `main` yet) | n/a (separate policy) | upstream `k8s/httproute.yaml` (backend :8000), chart `service.targetPort: 8000`; live Envoy labels |
| `payments-platform-egress` | payments | same (2) | n/a | kube-dns :53 UDP/TCP; `payments-db` pods :5432. Everything else denied | upstream NetworkPolicy egress; `DATABASE_URL` secretKeyRef only; `automount: false`; no HTTP client in `app/` |
| `payments-db-ingress` | payments | `cnpg.io/cluster=payments-db,podRole=instance` (1) | app + migration Job :5432; cnpg operator :8000,:5432; same cluster :5432,:8000 | open | upstream NP egress, `db.yaml`; live DB pod labels |
| `authentik-server-ingress` | authentik | server (`component=server`) (1) | Envoy `envoy-external` :9000; authentik worker :9000,:9443 (defensive) | open | `httproute.yaml` (authentik-server:80 -> 9000, live endpoints) |
| `authentik-worker-ingress` | authentik | worker (`component=worker`) (1) | authentik server :9000 (defensive) | open | no Service/consumer found for the worker |
| `authentik-db-ingress` | authentik | `cnpg.io/cluster=authentik-db` (1) | authentik pods :5432; cnpg operator :8000,:5432; same cluster | open | `helm-release.yaml` (`authentik-db-rw.authentik.svc`), `db.yaml` |
| `lifter-web-ingress` | lifter | `controller=web` (1) | Envoy `envoy-external` :80 | n/a | `helm-release.yaml` route backend `web:80` |
| `lifter-api-ingress` | lifter | `controller=api` (1) | lifter web :8000 | n/a | `helm-release.yaml`: "web image proxies /api/ to http://api:8000" |
| `lifter-db-ingress` | lifter | `cnpg.io/cluster=lifter-db` (1) | api :5432; cnpg operator :8000,:5432; same cluster | open | `PG_HOST=lifter-db-rw`, `PG_PORT=5432` |
| `lifter-egress-deny-lan` | lifter | `name=lifter,instance=lifter` (2) | n/a | all except `192.168.0.0/16`, `host`, `remote-node`, Envoy proxies `envoy-internal`/`envoy-nx`/`tcp-gateway` (3 pods), traefik-internal (1 pod). Other in-cluster Services stay reachable (section 2) | full container env in `helm-release.yaml` |
| `jellyfin-ingress` | apps | `name=jellyfin,instance=jellyfin` (1) | Envoy `envoy-external` :8096 | open (not restricted) | `httproute.yaml` (jellyfin:8096), live endpoints |
| `website-ingress` | apps | `name=website,instance=website` (3) | Envoy `envoy-external` :80 | n/a | `helm-release.yaml` route, Caddyfile `:80` |
| `website-egress` | apps | same (3) | n/a | kube-dns :53; `rook-ceph` pods `app=rook-ceph-rgw,rgw=ceph-objectstore` :8080 only | Caddyfile `reverse_proxy ...rook-ceph-rgw...`; Service 80 -> 8080 live |

Peer selectors verified live: Envoy proxies `external` = 1 pod, `internal` +
`external` = 2 pods; deny set `internal` + `nx` + `tcp-gateway` = 3 Running
pods (1 each; a Completed `envoy-nx` pod from an old ReplicaSet is not
counted); traefik-internal = 1 Running pod; cnpg operator = 1 pod; kube-dns =
2 Running pods; RGW = 2 pods. The payments migration Job pod selector (used only as a DB-ingress peer)
matches 0 pods outside a Helm upgrade (it is a hook Job).

## 4. Deliberately left open

| What | Why |
|---|---|
| Egress of authentik server/worker | SMTP, OAuth/OIDC/SAML/LDAP sources, webhooks, outposts, error reporting are configured in the UI/DB. Not provable from git. |
| Egress of jellyfin | Metadata/plugin downloads from the internet; LAN sources (tuners, DLNA) possible via UI config. NFS media is mounted by the kubelet, not by the pod. |
| Egress of all CNPG DB pods | API server, replication, future backups. |
| Ingress from other in-cluster clients to jellyfin (sonarr/radarr in `torrent`) | No evidence in git; commented rule in `app/jellyfin.yaml` shows how to add it. |
| Ingress from in-cluster clients to authentik-server | None in git (no consumer of `authentik-server.authentik.svc`); apps use `ak.grendel71.net` via Cloudflare. |
| flux-system | Existing NetworkPolicies are sufficient (section 1). |

## 5. Enabling enforcement

Nothing here has been run against a live Cilium: at the time of writing the
cluster still runs Flannel, so the Cilium-side commands below are taken from
the Cilium v1.20.4 chart, source and docs, not from a live run.

### 5.1 Prerequisites (read-only)

Run in the dev shell after Cilium is installed and `cilium-policies` is Ready:

```bash
kubectl get cnp -A                       # 17 policies; the VALID column must be True for every one
kubectl -n kube-system get cm cilium-config -o yaml \
  | grep -E 'enable-policy|enable-non-default-deny-policies|policy-audit-mode'
```

Expected before the flip: `enable-policy: never`,
`enable-non-default-deny-policies: "true"` (chart default; `release.yaml` does
not override it) and no `policy-audit-mode` line (the chart only renders it
when `policyAuditMode` is set in the values; it is commented out in the chart's
`values.yaml`). The `VALID` printer column of the CNP CRD is
`.status.conditions[?(@.type=='Valid')].status`.

### 5.2 Pre-flip discovery (do this BEFORE enforcing)

The policies in this repo are inferred from git and live labels, not from
observed traffic. Some flows exist that git cannot show. Find them while
nothing is dropped.

**Tooling.** The dev shell has no `hubble` or `cilium` CLI. Working options:

1. The `hubble` CLI is built into the Cilium agent image (the cilium container
   build includes the `hubble` command and sets
   `HUBBLE_SERVER=unix:///var/run/cilium/hubble.sock`, checked in the v1.20.4
   `Makefile` and `images/cilium/Dockerfile`). It only sees flows of **that
   node**, so loop over all agents:

   ```bash
   for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
     echo "== $p"
     kubectl -n kube-system exec "$p" -c cilium-agent -- \
       hubble observe --type policy-verdict --verdict AUDIT --last 2000
   done
   ```

2. Cluster-wide through Hubble Relay (TLS to clients is off by default in the
   chart, `hubble.relay.tls.server.enabled: false`):

   ```bash
   kubectl -n kube-system port-forward svc/hubble-relay 4245:80 &
   nix shell nixpkgs#hubble --command hubble observe --server localhost:4245 \
     --type policy-verdict --verdict AUDIT --last 2000
   ```

   (`nixpkgs#hubble` is 1.19.3 in the current channel, a client older than the
   1.20.4 server; the Flow API is stable but watch for flag differences.)

3. The Hubble UI at `https://hubble.internal.grendel71.net` (route in
   `../cilium/routes/httproute.yaml`): per-namespace service map and flow list
   with a verdict filter, if you prefer a GUI.

4. Raw per-node events from inside an agent: `kubectl -n kube-system exec
   <cilium-pod> -c cilium-agent -- cilium-dbg monitor -t policy-verdict`
   (`-t drop` for actual drops after enforcement). Event types accepted by the
   command: `agent capture debug drop l7 policy-verdict trace trace-sock`.

**Step A (recommended): first flip in policy AUDIT mode.** In
`k8s/infrastructure/cilium/app/release.yaml` values, make the first flip

```yaml
    policyEnforcementMode: default
    policyAuditMode: true        # TEMPORARY, remove in step C
```

The chart renders `policy-audit-mode: "true"` into `cilium-config` only when
the key `policyAuditMode` is present (`templates/cilium-configmap.yaml`:
`{{- if hasKey .Values "policyAuditMode" }}`). In audit mode Cilium allows all
traffic and records a policy-verdict event with verdict `AUDIT` (printed as
`policy-verdict:none AUDITED`) for every connection that would have been
dropped. In the v1.20.4 datapath (`bpf/lib/policy.h`) any policy error result
is turned into "allow + audited", which includes explicit `egressDeny` matches,
so denied destinations of `lifter` are audited too instead of
dropped. Audit mode documents L3/L4 only (these policies have no L7 rules).
**Everything is unenforced in this state**, including the upstream payments
NetworkPolicy; it is a discovery state, not a safe end state.

**Step B: collect and review.** Leave it running long enough to cover
periodic traffic (a day or more: CNPG operator and backups, Flux, migrations,
cron-like jobs). Use the loop from option 1 with `--follow` instead of
`--last` to watch live. Group by source (4th field of the compact output is
the source `namespace/pod:port`):

```bash
... hubble observe --type policy-verdict --verdict AUDIT --last 5000 \
  | awk '{print $4}' | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn
```

Rule: for traffic **to** the protected pods, a source that is not
`envoy-gateway-system`, `cnpg-system` or the same namespace needs an allow (or
is a flow you intend to keep blocked). For `lifter-egress-deny-lan`, any audited egress means a real LAN/proxy
dependency that must be carved out of the deny before enforcing.

Targeted per-target view (adjust the pod name prefix; useful to see exactly who
talks to one workload):

```bash
... hubble observe --to-pod apps/jellyfin --last 1000
... hubble observe --to-namespace authentik --to-label app.kubernetes.io/component=server --last 1000
```

Without audit mode (still `policyEnforcementMode: never`) the same `hubble
observe` commands only show ordinary trace flows (`FORWARDED`), not verdicts;
that was not verified on this cluster, so treat it as a hint, not a result.

**Pre-flip verification list (known likely gaps; resolve each one):**

- `torrent` namespace (sonarr, radarr, prowlarr, qbittorrent) -> `jellyfin`
  :8096. Library-update notifications are commonly configured in those apps'
  own databases. The allow is **commented out** in `app/jellyfin.yaml` (no
  evidence in git); uncomment/add it if audit shows these sources.
- Any in-cluster source -> `authentik-server` :9000 (outposts, other apps doing
  OIDC discovery against `authentik-server.authentik.svc`). None known in git.
- `lifter` web -> api :8000 is documented in `helm-release.yaml`. Confirm the
  flow exists.
- Egress audits of `lifter` pods (LAN, node, internal proxy
  destinations) should be empty.

**Step C: real enforcement.** Delete the `policyAuditMode` key (or set it to
`false`) in `release.yaml` and commit. It is a second rolling restart of the
agents (see below). Only then is traffic actually dropped.

### 5.3 The flip commit

(Combine with the audit steps above, or do the single commit if skipping
audit mode.) In `k8s/infrastructure/cilium/app/release.yaml` change

```yaml
    policyEnforcementMode: never
```

to

```yaml
    policyEnforcementMode: default
```

(and update the comment above it). `default` is Cilium's mode: a pod is
default-deny in a direction only if a policy selects it for that direction;
everything else stays open. `rollOutCiliumPods: true` restarts the agents when
the ConfigMap changes (rolling, one node at a time).

After the flip, verify:

```bash
for p in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --verdict DROPPED --last 500
done                                                      # expect nothing for the 4 namespaces below
curl -sI https://jellyfin.grendel71.net | head -1       # 200/302
curl -sI https://me.grendel71.net | head -1
curl -sI https://ak.grendel71.net | head -1
curl -sI https://lifter.grendel71.net | head -1
kubectl get clusters.postgresql.cnpg.io -A              # all "healthy"
flux get kustomizations                                  # no new False entries
```

The four namespaces with policies: `payments`, `authentik`,
`lifter`, `apps` (jellyfin and website pods only).

### 5.4 Rollback

**Fast path (seconds, no Cilium restart):** remove the policies, keep
enforcement mode. Suspend the Flux Kustomization first so Flux does not
re-apply them, then delete the CNPs **by name** (never `--all` in `apps`:
other CNPs may live there):

```bash
flux suspend kustomization cilium-policies -n flux-system
kubectl delete cnp -n payments payments-platform-ingress payments-platform-egress payments-db-ingress
kubectl delete cnp -n authentik authentik-server-ingress authentik-worker-ingress authentik-db-ingress
kubectl delete cnp -n lifter lifter-web-ingress lifter-api-ingress lifter-db-ingress lifter-egress-deny-lan
kubectl delete cnp -n apps jellyfin-ingress website-ingress website-egress
```

Caveats:

- This only removes **CiliumNetworkPolicies**. The existing Kubernetes
  NetworkPolicies are enforced as soon as the mode is `default`: the two in
  `payments` (the `payments-platform` one drops all ingress to the payments API
  because its allow selector matches no pod, see section 1) and the three in
  `flux-system` (harmless). Deleting the payments CNPs therefore **breaks** the
  payments API ingress; to roll back payments use the slow path below.
- Flux re-applies everything when you run
  `flux resume kustomization cilium-policies -n flux-system` (or the next
  interval after resume), so resuming without fixing the cause re-creates the
  same drops. Fix the policy in git first.

**Slow path (full revert, enforcement off):** set `policyEnforcementMode:
never` again (and drop `policyAuditMode`) in `release.yaml`, commit, then
`flux reconcile source git flux-system && flux reconcile helmrelease cilium -n
kube-system`. This needs a commit, a reconcile and the rolling Cilium restart
(one node at a time), so it is slow; use the fast path first when something
is dropped now.

## 6. Validation done for this change

- `kubectl kustomize k8s/infrastructure/cilium-policies/app` and
  `kubectl kustomize k8s` render.
- Every CNP validated with `kubeconform -strict` against the
  `CiliumNetworkPolicy` v2 schema extracted from the CRD of tag v1.20.4
  (`pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml`). Negative
  controls that the schema rejects: a misspelled entity value
  (`remote-nodee`), a bad `matchExpressions` operator (`Inn`) and a misspelled
  top-level rule key (`egressDeni`). It does **not** reject a misspelled
  nested field name such as `toEntitiez` (the CRD schema does not close those
  objects), so review field names by eye.
- Selector counts taken from live pods (table above). Nothing was applied to the
  cluster.
