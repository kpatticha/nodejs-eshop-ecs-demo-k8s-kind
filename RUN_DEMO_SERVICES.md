# Run the demo services — send APM data to Elastic with the classic agent

Run two Node.js demo services on a local Kubernetes cluster (kind), instrumented
with the **Elastic APM Node.js agent**, and ingest ECS-formatted traces into
Elastic.

Five steps, ~10 minutes. Only one of them needs anything from you: where the
APM data should go.

```
loadgen ──▶ frontend ──HTTP──▶ backend        (distributed trace, ECS)
            (NodePort :8080)   (ClusterIP)
               └── elastic-apm-node ──────────▶ APM Server ──▶ Elastic
```

The APM Server can either run **in the cluster**
([APM_SERVER.md](APM_SERVER.md), the default this repo ships with) or be a
**managed Elastic Cloud APM endpoint** — step 4 covers both.

## 1. Prerequisites

Docker Desktop, running, with **≥ 6 GB memory** allocated (Settings → Resources)
if you also plan to run the Elastic Agent, plus:

```bash
brew install kind kubectl
```

Node.js is only needed if you want to run the services outside Kubernetes.

## 2. Clone the repo

Run everything from the repo root:

```bash
git clone https://github.com/kpatticha/nodejs-eshop-ecs-demo-k8s-kind.git
cd nodejs-eshop-ecs-demo-k8s-kind
```

## 3. Create the cluster and deploy the apps

```bash
./scripts/setup.sh
```

Creates the kind cluster `eshop`, builds both service images, loads them into the
node, applies the manifests, and waits for all three rollouts. Safe to re-run at
any point. When it finishes, the storefront answers on
[http://localhost:8080](http://localhost:8080):

```bash
curl -s localhost:8080/api/products
```

Every `kubectl` call in the scripts is pinned to the `kind-eshop` context, so
having other clusters or a different current-context selected cannot make the
manifests land in the wrong place. Override with `CONTEXT=... ./scripts/setup.sh`.

## 4. Point APM somewhere

`k8s/apm-secret.example.yaml` ships with `ELASTIC_APM_ACTIVE` already `"true"`
and `server-url` pointing at the in-cluster APM Server, so the services are
trying to send data from the moment they start. Until an APM Server exists they
just log connection errors every few seconds; the storefront is unaffected.

**Option A — run APM Server in the cluster (default).** Nothing to edit; you
only need Elasticsearch credentials:

```bash
./scripts/apm-server.sh apply
```

See [APM_SERVER.md](APM_SERVER.md) for the credentials file and what it deploys.
That file is shared with the Elastic Agent, so if you already did
[K8S_MONITORING.md](K8S_MONITORING.md) there is nothing left to fill in.

**Option B — use a managed Elastic Cloud APM endpoint instead.** Override the
committed defaults:

```bash
cp k8s/apm-secret.example.yaml k8s/apm-secret.yaml
# edit the ecs-eshop document: set server-url to your APM endpoint and
# secret-token to its token. The kube-system document is only needed for
# option A, so you can leave or delete it.
kubectl --context kind-eshop apply -f k8s/apm-secret.yaml
./scripts/setup.sh
```

`k8s/apm-secret.yaml` is gitignored. Re-running setup restarts the deployments —
env vars sourced from a Secret are not picked up otherwise.

## 5. Generate traffic and look at it

The `ecs-loadgen` deployment already hits the storefront every two seconds. For a
burst on demand:

```bash
./scripts/traffic.sh
```

Sends 50 request pairs to `localhost:8080`. Pass a number for more:
`./scripts/traffic.sh 200`.

In Kibana:

- **Applications → Service Inventory** — `ecs-eshop-frontend` and
  `ecs-eshop-backend` appear in the `kind-local` environment.
- **Traces / Service map** — opening a frontend transaction shows the call to the
  backend as a child span. The agent propagates trace context across the HTTP
  call automatically, with no application code.

## 6. Next: Kubernetes metrics and logs

APM only tells you about the two services. For node, pod, container and cluster
metrics plus container logs, continue with
[K8S_MONITORING.md](K8S_MONITORING.md) — it reuses the same Elasticsearch
credentials file as the APM Server, then deploys Elastic Agent standalone.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Anything wrong with the cluster | Don't debug it — `kind delete cluster --name eshop`, then `./scripts/setup.sh` (~30s) |
| Pods stuck in `ImagePullBackOff` | Images weren't loaded into the node — re-run `./scripts/setup.sh` |
| `the path "k8s/..." does not exist` | You're not in the repo root — `cd` into the cloned directory |
| Port 8080 already in use | Change `hostPort` in `kind/cluster.yaml` and recreate the cluster |
| Nothing in Kibana APM | Check `active` is `"true"` in the secret and that you re-ran `./scripts/setup.sh` afterwards, then `kubectl --context kind-eshop -n ecs-eshop logs deploy/ecs-eshop-frontend \| grep -i apm` |
| APM agent logs `ECONNREFUSED` / `ENOTFOUND` | Using the in-cluster server but it is not deployed — `./scripts/apm-server.sh apply`. Otherwise `server-url` is wrong |
| APM agent logs `401` / `403` | Wrong `secret-token`. With the in-cluster server, the token must match in **both** documents of `k8s/apm-secret.yaml` |
| Using a **local** APM Server on your Mac | Pods can't reach `localhost` — use `http://host.docker.internal:8200` as `server-url` |

A healthy agent logs `conclude intake request: success` at
`ELASTIC_APM_LOG_LEVEL=trace`.

## Teardown

```bash
kind delete cluster --name eshop
```

---

Prefer to run each command yourself? [MANUAL.md](MANUAL.md) has the full
step-by-step version.
