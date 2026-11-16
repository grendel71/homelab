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
[Enabling enforcement](#enabling-enforcement).

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
  - `leaderboard`, `lifter`: LAN/nodes denied, everything else open (see below).
  - `authentik`, `jellyfin`: egress left **open** (destinations are configured
    at runtime in the app, not in git).
- **Prometheus:** none exists in the cluster (no monitoring namespace, no
  `monitoring.coreos.com` CRDs), so no scrape allow is added. Metrics ports
  (authentik 9300, CNPG 9187) stay closed.
- **No policy selects** pods in `kube-system`, `rook-ceph`, `flux-system`,
  `cnpg-system`, `metallb-system`, `envoy-gateway-system`, `cilium`, nor any
  other pod in `apps` than jellyfin and website.
- **LAN/node deny** (`leaderboard-egress-deny-lan`, `lifter-egress-deny-lan`):
  `egressDeny` to `192.168.0.0/16` and entities `host`, `remote-node`, with
  `enableDefaultDeny.egress: false`. This last field is mandatory: with the
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
| `payments-platform-ingress` | payments | `name=payments-platform,instance=payments-platform` (2) | Envoy proxies (`envoy-internal`, `envoy-external`) TCP 8000 | n/a (separate policy) | upstream `k8s/httproute.yaml` (backend :8000), chart `service.targetPort: 8000`; live Envoy labels |
| `payments-platform-egress` | payments | same (2) | n/a | kube-dns :53 UDP/TCP; `payments-db` pods :5432. Everything else denied | upstream NetworkPolicy egress; `DATABASE_URL` secretKeyRef only; `automount: false`; no HTTP client in `app/` |
| `payments-db-ingress` | payments | `cnpg.io/cluster=payments-db,podRole=instance` (1) | app + migration Job :5432; cnpg operator :8000,:5432; same cluster :5432,:8000 | open | upstream NP egress, `db.yaml`; live DB pod labels |
| `authentik-server-ingress` | authentik | server (`component=server`) (1) | Envoy `envoy-external` :9000; authentik worker :9000,:9443 (defensive) | open | `httproute.yaml` (authentik-server:80 -> 9000, live endpoints) |
| `authentik-worker-ingress` | authentik | worker (`component=worker`) (1) | authentik server :9000 (defensive) | open | no Service/consumer found for the worker |
| `authentik-db-ingress` | authentik | `cnpg.io/cluster=authentik-db` (1) | authentik pods :5432; cnpg operator :8000,:5432; same cluster | open | `helm-release.yaml` (`authentik-db-rw.authentik.svc`), `db.yaml` |
| `leaderboard-web-ingress` | leaderboard | `controller=web` (1) | Envoy `envoy-external` :80 | n/a | `helm-release.yaml` route backend `web:80` |
| `leaderboard-api-ingress` | leaderboard | `controller=api` (1) | leaderboard web :8080 | n/a | Service `api` 8080; inferred web -> api |
| `leaderboard-db-ingress` | leaderboard | `cnpg.io/cluster=leaderboard-db` (1) | api :5432; cnpg operator :8000,:5432; same cluster | open | `DATABASE_URL=...leaderboard-db-rw:5432` |
| `leaderboard-egress-deny-lan` | leaderboard | `name=leaderboard,instance=leaderboard` (2) | n/a | all except `192.168.0.0/16`, `host`, `remote-node` | full container env in `helm-release.yaml`: no LAN/node dependency |
| `lifter-web-ingress` | lifter | `controller=web` (1) | Envoy `envoy-external` :80 | n/a | `helm-release.yaml` route backend `web:80` |
| `lifter-api-ingress` | lifter | `controller=api` (1) | lifter web :8000 | n/a | `helm-release.yaml`: "web image proxies /api/ to http://api:8000" |
| `lifter-db-ingress` | lifter | `cnpg.io/cluster=lifter-db` (1) | api :5432; cnpg operator :8000,:5432; same cluster | open | `PG_HOST=lifter-db-rw`, `PG_PORT=5432` |
| `lifter-egress-deny-lan` | lifter | `name=lifter,instance=lifter` (2) | n/a | all except `192.168.0.0/16`, `host`, `remote-node` | full container env in `helm-release.yaml` |
| `jellyfin-ingress` | apps | `name=jellyfin,instance=jellyfin` (1) | Envoy `envoy-external` :8096 | open (not restricted) | `httproute.yaml` (jellyfin:8096), live endpoints |
| `website-ingress` | apps | `name=website,instance=website` (3) | Envoy `envoy-external` :80 | n/a | `helm-release.yaml` route, Caddyfile `:80` |
| `website-egress` | apps | same (3) | n/a | kube-dns :53; `rook-ceph` pods `app=rook-ceph-rgw,rgw=ceph-objectstore` :8080 only | Caddyfile `reverse_proxy ...rook-ceph-rgw...`; Service 80 -> 8080 live |

Peer selectors verified live: Envoy proxies `external` = 1 pod, `internal` +
`external` = 2 pods; cnpg operator = 1 pod; kube-dns = 2 Running pods; RGW = 2
pods. The payments migration Job pod selector (used only as a DB-ingress peer)
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

Prerequisites (all read-only, run in the dev shell after Cilium is installed
and `cilium-policies` is Ready):

```bash
kubectl get ciliumnetworkpolicies -A                        # 17 policies, no errors
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-non-default-deny-policies}{"\n"}'   # true
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i "policy"
kubectl get cnp -A      # VALID column, if shown, must be True
```

The follow-up commit (separate from this one): in
`k8s/infrastructure/cilium/app/release.yaml` change

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
hubble observe --verdict DROPPED --namespace payments --namespace authentik \
  --namespace leaderboard --namespace lifter --namespace apps
curl -sI https://jellyfin.grendel71.net | head -1       # 200/302
curl -sI https://me.grendel71.net | head -1
curl -sI https://ak.grendel71.net | head -1
curl -sI https://strength.grendel71.net | head -1
curl -sI https://lifter.grendel71.net | head -1
kubectl get clusters.postgresql.cnpg.io -A              # all "healthy"
flux get kustomizations                                  # no new False entries
```

Rollback: set `policyEnforcementMode: never` again (same rolling restart).

## 6. Validation done for this change

- `kubectl kustomize k8s/infrastructure/cilium-policies/app` and
  `kubectl kustomize k8s` render.
- Every CNP validated with `kubeconform -strict` against the
  `CiliumNetworkPolicy` v2 schema extracted from the CRD of tag v1.20.4
  (`pkg/k8s/apis/cilium.io/client/crds/v2/ciliumnetworkpolicies.yaml`); a
  deliberately misspelled field/entity is rejected, so the check is effective.
- Selector counts taken from live pods (table above). Nothing was applied to the
  cluster.
