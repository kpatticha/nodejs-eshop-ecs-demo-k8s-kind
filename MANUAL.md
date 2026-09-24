# Manual runbook — every command, one at a time

This is the long form of [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md),
[APM_SERVER.md](APM_SERVER.md) and [K8S_MONITORING.md](K8S_MONITORING.md). Same
result, but you run each command yourself instead of the scripts. Use it when you
want to understand each step, or when something broke and you need to poke at
it.

Every step is a standard `kind` / `docker` / `kubectl` command.

```
loadgen ──▶ frontend ──HTTP──▶ backend        (distributed trace, ECS)
            (NodePort :8080)   (ClusterIP)      namespace ecs-eshop
               └── elastic-apm-node ──────────▶ APM Server ──▶ Elastic
                                                (kube-system)  ▲
      node/pod/container metrics + logs ──▶ Elastic Agent ─────┘
                                            (kube-system)
```

APM Server and Elastic Agent both live in `kube-system` and read one shared
Secret, `elasticsearch-credentials`.

Every `kubectl` below carries `--context kind-eshop`. That is deliberate: with
more than one local kind cluster around, the current context drifts, and an
unpinned `kubectl apply` silently lands the manifests in the wrong cluster.

## 1. Prerequisites

- Docker Desktop, running, with **≥ 6 GB memory** allocated (Settings →
  Resources) if you also plan to run the Elastic Agent
- kind and kubectl:

```bash
brew install kind kubectl
```

## 2. Clone the repo

Run **all remaining commands from the repo root** — every path below is relative
to it:

```bash
git clone https://github.com/kpatticha/nodejs-eshop-ecs-demo-k8s-kind.git
cd nodejs-eshop-ecs-demo-k8s-kind
```

## 3. Create the cluster

The cluster config is committed as [kind/cluster.yaml](kind/cluster.yaml). It is
a single control-plane node that maps NodePort 30080 to host port 8080, which is
how the storefront becomes reachable at `http://localhost:8080`:

```bash
kind create cluster --name eshop --config kind/cluster.yaml --wait 120s
```

This creates a cluster named `eshop` and switches your kubectl context to
`kind-eshop`. Verify:

```bash
kubectl --context kind-eshop get nodes
```

If anything is ever wrong with the cluster, don't debug it — recreate it (takes
~30 seconds):

```bash
kind delete cluster --name eshop
```

## 4. Build and load the images

Build both images and load them into the kind node (no registry needed):

```bash
docker build -t ecs-eshop-backend:dev services/backend
docker build -t ecs-eshop-frontend:dev services/frontend
kind load docker-image ecs-eshop-backend:dev ecs-eshop-frontend:dev --name eshop
```

Both Deployments use `imagePullPolicy: IfNotPresent`, so the loaded images are
used as-is and nothing is ever pulled from a registry.

## 5. Create the APM secret

The Deployments expect a Secret named `apm-credentials`, so one has to exist
before they can start. The committed template already has `active: "true"` and
points at the in-cluster APM Server (step 10), so applying it as-is is usually
what you want:

```bash
kubectl --context kind-eshop apply -f k8s/namespace.yaml
kubectl --context kind-eshop apply -f k8s/apm-secret.example.yaml
```

It has **two documents**: `apm-credentials` in `ecs-eshop` for the services, and
the same Secret in `kube-system` for the APM Server, which needs the matching
`secret-token`. Change the token in one and you must change it in the other.

To send to a managed Elastic Cloud APM endpoint instead, override it:

```bash
kubectl --context kind-eshop apply -f k8s/namespace.yaml
cp k8s/apm-secret.example.yaml k8s/apm-secret.yaml
# edit the ecs-eshop document: your server-url and secret-token
kubectl --context kind-eshop apply -f k8s/apm-secret.yaml
```

`k8s/apm-secret.yaml` is gitignored. Setting `active` back to `"false"` loads the
APM agent but switches it off, and the services never try to reach a server.

## 6. Deploy the services

```bash
kubectl --context kind-eshop apply \
  -f k8s/backend.yaml -f k8s/frontend.yaml -f k8s/loadgen.yaml
```

Wait for the rollouts:

```bash
kubectl --context kind-eshop -n ecs-eshop rollout status deployment/ecs-eshop-backend --timeout=120s
kubectl --context kind-eshop -n ecs-eshop rollout status deployment/ecs-eshop-frontend --timeout=120s
kubectl --context kind-eshop -n ecs-eshop rollout status deployment/ecs-loadgen --timeout=120s
```

Verify all three pods are `Running`:

```bash
kubectl --context kind-eshop -n ecs-eshop get pods -o wide
```

If the deployments already existed — or if you changed the secret — restart them.
Env vars sourced from a Secret are read at container start and are not picked up
otherwise:

```bash
kubectl --context kind-eshop -n ecs-eshop rollout restart \
  deployment ecs-eshop-backend ecs-eshop-frontend
```

## 7. Generate traffic

`ecs-loadgen` already hits the storefront every two seconds. For a burst on
demand, no port-forward needed — the NodePort is mapped to host 8080:

```bash
curl -s localhost:8080/api/products
for i in $(seq 1 50); do
  curl -s -o /dev/null localhost:8080/
  curl -s -o /dev/null localhost:8080/api/products
done
```

Tail the service logs while it runs:

```bash
kubectl --context kind-eshop -n ecs-eshop logs \
  -l 'app in (ecs-eshop-frontend,ecs-eshop-backend)' --tail=50 -f --prefix
```

## 8. See it in Kibana

- **Applications → Service Inventory** — `ecs-eshop-frontend` and
  `ecs-eshop-backend` appear in the `kind-local` environment.
- **Traces / Service map** — opening a frontend transaction shows the call to the
  backend as a child span, correlated by the `traceparent` header the agent
  propagates automatically.

## 9. The shared Elasticsearch credentials

Both the APM Server (step 10) and the Elastic Agent (step 11) authenticate to the
same remote Elasticsearch with **basic auth**, from one Secret:
`elasticsearch-credentials` in `kube-system`. They run in the same namespace
precisely so they can share it — Secrets are namespace-scoped.

```bash
cp k8s/common/elasticsearch-secret.example.yaml k8s/common/elasticsearch-secret.yaml
# edit: set es-host, username and password
kubectl --context kind-eshop apply -f k8s/common/elasticsearch-secret.yaml
```

`k8s/common/elasticsearch-secret.yaml` is gitignored. See
[APM_SERVER.md](APM_SERVER.md) for the role the user needs — note the
`.apm-agent-configuration` `read` privilege, which is easy to miss and produces a
`security_exception` every 30 seconds when absent.

Reusing the Elasticsearch you already set up for the OTel demo? Take the values
from your local Kibana's `config/kibana.dev.yml` — `elasticsearch.hosts`,
`elasticsearch.username`, `elasticsearch.password` — or from the local Kibana
login page.

## 10. APM Server

The scripted version is [APM_SERVER.md](APM_SERVER.md); this is the same thing by
hand. Skip it if you pointed `server-url` at a managed Elastic Cloud APM endpoint
in step 5.

The APM Server needs both Secrets: the shared one from step 9 for Elasticsearch,
and the `kube-system` copy of `apm-credentials` for the token the services use.
Step 5 applied both documents already, so this is just the manifest:

```bash
kubectl --context kind-eshop apply -f k8s/apm-server/apm-server.yaml
kubectl --context kind-eshop -n kube-system rollout status deploy/apm-server --timeout=120s
```

Check it reached Elasticsearch — `publish_ready` is the field that matters:

```bash
kubectl --context kind-eshop -n kube-system port-forward svc/apm-server 8200:8200 &
curl -s -H "Authorization: Bearer replace-me" localhost:8200/ | python3 -m json.tool
```

`GET /` without a token also answers `200`, with an empty body — the root
endpoint deliberately does not require auth, and that is what the readiness probe
uses. The token is enforced on the intake endpoints:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer wrong" localhost:8200/intake/v2/events   # 401
```

Logs, and the metrics lines that show events being accepted and published:

```bash
kubectl --context kind-eshop -n kube-system logs deploy/apm-server --tail=100 -f
```

After changing the config or either Secret, roll it. The config is a `subPath`
ConfigMap mount, which kubelet never refreshes in place, and env vars from a
Secret are only read at container start:

```bash
kubectl --context kind-eshop apply -f k8s/apm-server/apm-server.yaml
kubectl --context kind-eshop -n kube-system rollout restart deploy/apm-server
```

Remove it again — leaving the shared Secret alone, since the agent uses it:

```bash
kubectl --context kind-eshop delete -f k8s/apm-server/apm-server.yaml --ignore-not-found
kubectl --context kind-eshop -n kube-system delete secret apm-credentials --ignore-not-found
```

## 11. Elastic Agent standalone

The scripted version is [K8S_MONITORING.md](K8S_MONITORING.md); this is the same
thing by hand. It uses the credentials from step 9.

Apply kube-state-metrics, the secret, then the agent:

```bash
kubectl --context kind-eshop apply -f k8s/elastic-agent/kube-state-metrics.yaml
kubectl --context kind-eshop apply -f k8s/common/elasticsearch-secret.yaml
kubectl --context kind-eshop apply -f k8s/elastic-agent/elastic-agent-standalone.yaml
```

Wait for both:

```bash
kubectl --context kind-eshop -n kube-system rollout status deploy/kube-state-metrics --timeout=120s
kubectl --context kind-eshop -n kube-system rollout status ds/elastic-agent-standalone --timeout=180s
```

Check the logs:

```bash
kubectl --context kind-eshop -n kube-system logs ds/elastic-agent-standalone --tail=100 -f
```

After changing credentials, re-apply the secret and roll the DaemonSet:

```bash
kubectl --context kind-eshop apply -f k8s/common/elasticsearch-secret.yaml
kubectl --context kind-eshop -n kube-system rollout restart ds/elastic-agent-standalone
```

Remove it again. Note the shared Secret is *not* deleted here — the APM Server
reads it too, and deleting it would break that Deployment at its next restart:

```bash
kubectl --context kind-eshop delete -f k8s/elastic-agent/elastic-agent-standalone.yaml --ignore-not-found
kubectl --context kind-eshop delete -f k8s/elastic-agent/kube-state-metrics.yaml --ignore-not-found
```

Once nothing else needs the credentials:

```bash
kubectl --context kind-eshop -n kube-system delete secret elasticsearch-credentials --ignore-not-found
```

## Reference: how the APM agent is wired in

Both services start with:

```
node -r elastic-apm-node/start.js server.js
```

There is no `apm.start()` call in the source. All configuration comes from the
environment, set in `k8s/backend.yaml` and `k8s/frontend.yaml`:

| Variable | Where it comes from |
| --- | --- |
| `ELASTIC_APM_SERVICE_NAME` | literal, per Deployment |
| `ELASTIC_APM_ENVIRONMENT` | literal — `kind-local` |
| `ELASTIC_APM_LOG_LEVEL` | literal — `info` |
| `ELASTIC_APM_ACTIVE` | Secret `apm-credentials`, key `active` |
| `ELASTIC_APM_SERVER_URL` | Secret `apm-credentials`, key `server-url` |
| `ELASTIC_APM_SECRET_TOKEN` | Secret `apm-credentials`, key `secret-token` |
| `KUBERNETES_NODE_NAME` | downward API — `spec.nodeName` |
| `KUBERNETES_POD_NAME` | downward API — `metadata.name` |
| `KUBERNETES_POD_UID` | downward API — `metadata.uid` |
| `KUBERNETES_NAMESPACE` | downward API — `metadata.namespace` |

The four `KUBERNETES_*` variables are what put `kubernetes.*` fields on the
traces. The agent normally infers them from `/proc/self/cgroup`, but under
cgroup v2 — which is what kind and current Docker Desktop use — that file is
just `0::/`, with no pod UID or container ID in it. Without the downward API
the services show up in Kibana APM as if they were not running on Kubernetes at
all: no pod name, no node, and no correlation with the Elastic Agent's
infrastructure data.

## Reference: endpoints

**frontend** (`http://localhost:8080`)

| Route | Description |
| --- | --- |
| `GET /` | HTML product listing, rendered from the backend response |
| `GET /api/products` | JSON proxy to the backend |
| `GET /healthz` | liveness/readiness probe |

**backend** (in-cluster only, `http://ecs-backend.ecs-eshop.svc.cluster.local:3000`)

| Route | Description |
| --- | --- |
| `GET /products` | all products |
| `GET /products/:id` | one product, `404` when unknown |
| `GET /healthz` | liveness/readiness probe |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `the path "k8s/..." does not exist` | You're not in the repo root — `cd` into the cloned directory |
| Cluster misbehaving, apiserver unreachable | `kind delete cluster --name eshop`, then recreate from step 3 |
| Pods `ImagePullBackOff` | Images weren't loaded into the node — rerun the `kind load docker-image ...` command from step 4 |
| Pods stuck `ContainerCreating` on a secret | `apm-credentials` does not exist yet — step 5 |
| Port 8080 already in use | Change `hostPort` in `kind/cluster.yaml` and recreate the cluster |
| Manifests landed in the wrong cluster | A `kubectl` without `--context kind-eshop` — check `kubectl config current-context` |
| Nothing in Kibana APM | `active` must be `"true"` **and** the pods restarted afterwards (step 6) |
| APM agent logs `ECONNREFUSED` / `ENOTFOUND` | The in-cluster APM Server is not deployed (step 10), or `server-url` is missing the `.kube-system.svc.cluster.local` part |
| APM agent logs `401` / `403` | `secret-token` differs between the two documents of the APM secret (step 5) |
| APM Server reports `publish_ready: false` | Its Elasticsearch output cannot connect or authenticate — check the step 9 credentials in its logs |
| `security_exception` on `.apm-agent-configuration` | The Elasticsearch user lacks `read` on that index (step 9) |
| Using a **local** APM Server or Elasticsearch on your Mac | Pods can't reach `localhost` — use `host.docker.internal` instead |

## Teardown

```bash
kind delete cluster --name eshop
```
