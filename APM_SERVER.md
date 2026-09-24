# APM Server — the in-cluster ingest endpoint

The two Node.js services are instrumented with the classic Elastic APM agent,
but that agent needs somewhere to send data. This runs a **standalone APM
Server** in the same kind cluster, shipping straight to the same remote
Elasticsearch the Elastic Agent uses:

```
frontend ─┐
backend  ─┴── elastic-apm-node ──▶ apm-server ──▶ remote Elasticsearch
              (ecs-eshop)          (kube-system)  ▲
                                                  │
              Elastic Agent standalone ───────────┘
              (kube-system)
```

Prefer a managed APM endpoint instead? Skip this guide entirely and put your
Elastic Cloud APM URL in `server-url`, see
[RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md).

## One credentials file for both components

APM Server runs in `kube-system`, not `ecs-eshop`. That is deliberate: Secrets
are namespace-scoped, so it is the only way APM Server and the Elastic Agent
DaemonSet can read the *same* Secret object rather than two copies of the same
credentials.

| | |
| --- | --- |
| Template | `k8s/common/elasticsearch-secret.example.yaml` |
| Real file | `k8s/common/elasticsearch-secret.yaml` (gitignored) |
| Secret | `elasticsearch-credentials` in `kube-system`, keys `es-host` / `username` / `password` |
| Read by | the APM Server Deployment **and** the Elastic Agent DaemonSet |

## 1. Fill in the credentials

Same file as [K8S_MONITORING.md](K8S_MONITORING.md) — if you already did that
step, you are done here and can go straight to step 2.

```bash
cp k8s/common/elasticsearch-secret.example.yaml k8s/common/elasticsearch-secret.yaml
# edit: set es-host, username and password
```

The user needs to publish to both the agent's and APM Server's data streams.
One role covers both:

```
cluster:  ["monitor"]
indices:  names ["logs-*-*", "metrics-*-*", "traces-*-*", "synthetics-*-*"]
          privileges ["auto_configure", "create_doc"]
          names [".apm-agent-configuration"]
          privileges ["read"]
```

`.apm-agent-configuration` is easy to miss. `elastic-apm-node` polls for central
agent config every 30 seconds, and APM Server answers by reading that index with
these same credentials — without the privilege you get a `security_exception`
log line forever. Using the `elastic` superuser hides this (and every other
privilege mistake), so the list above is only really exercised with a scoped
role.

## 2. Deploy

```bash
./scripts/apm-server.sh apply
```

Applies the namespace, the shared Elasticsearch Secret, the `apm-credentials`
Secret and the APM Server itself, then waits for the rollout. The other
subcommands:

| Command | Does |
| --- | --- |
| `./scripts/apm-server.sh status` | show the APM Server pod |
| `./scripts/apm-server.sh logs` | tail the APM Server logs |
| `./scripts/apm-server.sh restart` | re-apply secrets and config, then roll the Deployment |
| `./scripts/apm-server.sh down` | remove APM Server (leaves the shared Elasticsearch Secret alone) |

`restart` is needed after *any* config change: env vars from a Secret are read
at container start, and the config file is a `subPath` ConfigMap mount, which
kubelet never refreshes in place.

## 3. Point the services at it

The committed `k8s/apm-secret.example.yaml` already does this — `active: "true"`
and `server-url: http://apm-server.kube-system.svc.cluster.local:8200`. The FQDN
is required because the services are in a different namespace.

That file has **two documents**: Secret `apm-credentials` in `ecs-eshop` for the
services, and the same Secret in `kube-system` for APM Server, which needs the
matching token. Change the token in one and you must change it in the other, or
the services get `401`.

Restart the services so they re-read the Secret:

```bash
./scripts/setup.sh
```

## 4. Check it works

```bash
kubectl --context kind-eshop -n kube-system port-forward svc/apm-server 8200:8200 &
curl -s -H "Authorization: Bearer replace-me" localhost:8200/ | python3 -m json.tool
```

`"publish_ready": true` is the signal that matters — it means the Elasticsearch
output connected and authenticated. If it is `false`, read the logs before
looking anywhere else.

`GET /` answers `200` with an empty body without a token; that is by design (the
root endpoint does not require auth) and is what the readiness probe uses. To
confirm the token is actually enforced:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer wrong" localhost:8200/intake/v2/events   # 401
```

Then send traffic and watch the server side:

```bash
./scripts/traffic.sh
./scripts/apm-server.sh logs | grep -i "Non-zero metrics"
```

Look for `apm-server.server.response.valid.accepted` and
`output.elasticsearch.events.acked` climbing, with `.errors` staying at zero.
In Kibana → **Applications → Service Inventory**, `ecs-eshop-frontend` and
`ecs-eshop-backend` appear in the `kind-local` environment.

## Kubernetes metadata on the traces

`k8s/frontend.yaml` and `k8s/backend.yaml` pass four downward-API variables —
`KUBERNETES_NODE_NAME`, `KUBERNETES_POD_NAME`, `KUBERNETES_POD_UID` and
`KUBERNETES_NAMESPACE` — which are the exact names `elastic-apm-node` reads.

They are not optional here. The agent normally works the pod out from
`/proc/self/cgroup`, but on cgroup v2 (kind, current Docker Desktop) that file
is just `0::/` — no pod UID, no container ID. Drop the variables and the
services appear in Kibana APM with no `kubernetes.*` fields at all, as though
they were not running on Kubernetes, and nothing correlates them with the
Elastic Agent's pod and container metrics.

Check it on a running pod:

```bash
kubectl --context kind-eshop -n ecs-eshop logs deploy/ecs-eshop-frontend \
  | grep -o '"kubernetesPodName":{[^}]*}'
```

## What is deployed

| File | Contents |
| --- | --- |
| `k8s/apm-server/apm-server.yaml` | ConfigMap `apm-server`, the Deployment and a ClusterIP Service — all in `kube-system` |
| `k8s/common/elasticsearch-secret.example.yaml` | template for Secret `elasticsearch-credentials`, shared with the Elastic Agent |
| `k8s/apm-secret.example.yaml` | template for Secret `apm-credentials` in both `ecs-eshop` and `kube-system` |

Image `docker.elastic.co/apm/apm-server:9.5.4`, pinned literally. Keep it at or
below your Elasticsearch version, the same rule the vendored Elastic Agent
follows.

The config is deliberately small. RUM stays off (nothing here loads a browser
agent, and enabling it would also switch on anonymous auth alongside the secret
token), and self-instrumentation stays off so Kibana APM only lists the two
`ecs-*` services. Nothing needs to be installed on the Elasticsearch side: 9.x
APM Server does no index management — the built-in `apm-data` plugin owns the
templates, ILM policies and ingest pipelines, so there is no Fleet integration
step and no `wait_for_integration`.

## kind-specific caveats

- Traffic from the services to APM Server is plain `http` inside the cluster.
  Fine here; do not carry the pattern into a real cluster.
- Memory: APM Server limits 512Mi on top of the Elastic Agent's 1200Mi and the
  apps. Give Docker Desktop ≥ 6 GB or something gets OOMKilled.
- The Service is ClusterIP only. Use `port-forward` to reach it from your Mac;
  a local APM agent outside the cluster cannot reach it directly.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `publish_ready: false` | `./scripts/apm-server.sh logs` — almost always wrong `es-host` or credentials in `k8s/common/elasticsearch-secret.yaml` |
| Services log `401` | The `secret-token` differs between the two documents of `k8s/apm-secret.yaml` |
| Services log `ECONNREFUSED` / `ENOTFOUND` | APM Server is not deployed yet (`./scripts/apm-server.sh apply`), or `server-url` is missing the `.kube-system.svc.cluster.local` part |
| `security_exception` on `.apm-agent-configuration` every 30s | The Elasticsearch user lacks `read` on that index — see step 1 |
| `403` when publishing | The user lacks `auto_configure` / `create_doc` on `traces-apm*`, `logs-apm*`, `metrics-apm*` |
| Config edits have no effect | `subPath` ConfigMap mounts never refresh — `./scripts/apm-server.sh restart` |
| Pod `CrashLoopBackOff` right after start | A `${VAR}` in the config had no matching env var; the logs name it |
| Pod `OOMKilled` | Raise Docker Desktop's memory allocation |
