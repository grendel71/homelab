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
