# Kubernetes monitoring — Elastic Agent standalone

Step 4 of the demo, and the other half of the data. APM covers the two services;
node, pod, container and cluster metrics plus container logs come from **Elastic
Agent standalone** running in the same kind cluster, following the
[Fleet docs](https://www.elastic.co/docs/reference/fleet/running-on-kubernetes-standalone).
It ships straight to the same remote Elasticsearch — no Fleet Server, no OTel
collector.

This agent monitors **this** kind cluster (`eshop`). Running the OTel demo's EDOT
collectors in their own cluster at the same time, pointed at the same
Elasticsearch, gives you both shapes of Kubernetes data in one stack.

## 1. Fill in the credentials

The vendored manifest authenticates with **basic auth**, from the same Secret
the APM Server uses — `elasticsearch-credentials` in `kube-system`. If you
already did [APM_SERVER.md](APM_SERVER.md), this step is done; skip to step 2.

The user needs privileges to publish to the agent's data streams — a dedicated
role is enough:

```
cluster:  ["monitor"]
indices:  names ["logs-*-*", "metrics-*-*", "traces-*-*", "synthetics-*-*"]
          privileges ["auto_configure", "create_doc"]
          names [".apm-agent-configuration"]
          privileges ["read"]
```

The `kibana_system` user does **not** have these — the agent gets 403s. The
`.apm-agent-configuration` line is only needed by the APM Server, but the role
covers both components since they share one user.

```bash
cp k8s/common/elasticsearch-secret.example.yaml k8s/common/elasticsearch-secret.yaml
# edit: set es-host, username and password
```

**Reusing the cluster you already set up for the OTel demo?** Then this is the
only step you need from it — no new cluster, no new user. Copy
`elasticsearch.hosts`, `elasticsearch.username` and `elasticsearch.password`
out of your local Kibana's `config/kibana.dev.yml` into `es-host`, `username`
and `password` here. The same credentials are printed on the local Kibana login
page. Both demos then ship into one Elasticsearch, and you tell them apart by
`kubernetes.namespace` (`ecs-eshop` vs the OTel demo's namespace).

`k8s/common/elasticsearch-secret.yaml` is gitignored. No `ssl` settings are needed for
Elastic Cloud endpoints — they use a publicly trusted CA. For a self-signed
cluster, set the `CA_TRUSTED` env var in the DaemonSet to the root CA's SHA-256
fingerprint.

## 2. Deploy

```bash
./scripts/agent.sh apply
```

Applies kube-state-metrics, the secret and the agent, then waits for both
rollouts. The other subcommands:

| Command | Does |
| --- | --- |
| `./scripts/agent.sh status` | show the agent and kube-state-metrics pods |
| `./scripts/agent.sh logs` | tail the agent logs |
| `./scripts/agent.sh restart` | re-apply the secret and roll the DaemonSet (needed after a credentials change — env vars from a Secret are not picked up otherwise) |
| `./scripts/agent.sh down` | remove the agent and kube-state-metrics — the shared Secret is left in place because the APM Server uses it |
| `./scripts/agent.sh es-secret-down` | delete the shared `elasticsearch-credentials` Secret, once nothing else needs it |

## 3. Check the data

In Kibana → **Discover**:

| Index | What to expect |
| --- | --- |
| `metrics-kubernetes.*` | datasets `kubernetes.pod`, `.node`, `.container`, `.state_pod`, `.state_deployment` |
| `logs-kubernetes.container_logs-*` | filter `kubernetes.namespace: ecs-eshop` for the frontend/backend stdout |

The **Infrastructure → Kubernetes** dashboards should populate within a minute or
two — `ecs-loadgen` keeps the cluster busy.

## What is deployed

| File | Contents |
| --- | --- |
| `k8s/elastic-agent/elastic-agent-standalone.yaml` | ConfigMap `agent-node-datastreams`, the DaemonSet, RBAC — all in `kube-system` |
| `k8s/elastic-agent/kube-state-metrics.yaml` | kube-state-metrics v2.20.0, rendered from its upstream kustomize base |
| `k8s/common/elasticsearch-secret.example.yaml` | template for Secret `elasticsearch-credentials`, shared with the APM Server |

The agent manifest is a **pinned, vendored copy** of upstream v9.5.4 with three
local edits, listed in the comment header of the file: basic auth with
credentials from the Secret instead of the upstream api_key literals; the
`system-logs`, `windows-event-log` and `audit-log` inputs removed because they
collect nothing on kind; and the Secret renamed to `elasticsearch-credentials`
so the APM Server can share it.

To move to a newer version, re-vendor from
`https://raw.githubusercontent.com/elastic/elastic-agent/v<version>/deploy/kubernetes/elastic-agent-standalone-kubernetes.yaml`,
re-apply those three edits, and keep the agent version at or below your
Elasticsearch version.

## kind-specific caveats

- `kubernetes.controllermanager`, `kubernetes.scheduler` and `kubernetes.proxy`
  stay empty or sparse: in kind those components bind their metrics endpoints to
  `127.0.0.1` inside their own containers.
- `system.*` metrics describe the kind **node container**, not your Mac.
- The DaemonSet requests 500Mi and limits 1200Mi — by far the largest thing in
  the cluster, and the APM Server adds another 512Mi on top. Give Docker Desktop
  enough memory or something will be OOMKilled.
- Only one node, so there is exactly one agent pod and it holds the leader lock
  that drives the cluster-wide (kube-state-metrics, events, apiserver) inputs.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Nothing in Kibana | `./scripts/agent.sh logs` |
| `401` / `403` in the agent logs | Wrong username/password, or the user lacks the privileges above |
| `x509` or `connection refused` | `es-host` is wrong, or the cluster uses a self-signed CA (set `CA_TRUSTED`) |
| Missing `kubernetes.state_*` datasets | kube-state-metrics is not running — `./scripts/agent.sh status` |
| "A DaemonSet from a different source is already installed" | An `elastic-agent-standalone` DaemonSet applied outside this repo is in the cluster. Its pod selector is immutable, so it cannot be updated in place: `./scripts/agent.sh down`, then `./scripts/agent.sh apply` |
| Agent pod `OOMKilled` | Raise Docker Desktop's memory allocation |
