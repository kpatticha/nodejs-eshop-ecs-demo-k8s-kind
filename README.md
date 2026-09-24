# nodejs-eshop-ecs-demo-k8s-kind: local Kubernetes + Elastic APM (ECS) demo

Two Node.js services (`frontend` → `backend`) on a local [kind](https://kind.sigs.k8s.io/)
cluster, instrumented with the **classic Elastic APM Node.js agent**
(`elastic-apm-node`, ECS data), alongside an **Elastic Agent standalone**
DaemonSet collecting Kubernetes metrics and container logs. No OpenTelemetry
anywhere.

```
loadgen ──▶ frontend ──HTTP──▶ backend        (distributed trace, ECS)
            (NodePort :8080)   (ClusterIP)      namespace ecs-eshop
               └── elastic-apm-node ──────────▶ APM Server ──▶ Elastic
                                                (kube-system)  ▲
      node/pod/container metrics + logs ──▶ Elastic Agent ─────┘
                                            (standalone DaemonSet, kube-system)
```

APM Server and Elastic Agent both run in `kube-system` and read their
Elasticsearch credentials from **one** shared Secret,
`k8s/common/elasticsearch-secret.yaml`.

## Steps

## Steps

**1. Set up remote Elasticsearch and local Kibana** — use the OTel demo's runbook:

[REMOTE_ES_ELASTIC_AGENT_LOCAL_KIBANA.md](https://github.com/kpatticha/nodejs-eshop-otel-demo-k8s-kind/blob/main/REMOTE_ES_ELASTIC_AGENT_LOCAL_KIBANA.md)

Follow **phases 1 and 2 only**.

**Already did this for the OTel demo? Skip to step 2**

**2. Configure the Elasticsearch credentials**

Create your local secret file from the example:

```bash
cp k8s/common/elasticsearch-secret.example.yaml k8s/common/elasticsearch-secret.yaml
```

All you need is the **Elasticsearch URL and password** (you can use the same ones from kibana.yml)

**2. Deploy the demo services.** Run this from the repository root:

```bash
./scripts/setup.sh
```

This creates the kind cluster, builds and deploys the frontend and backend, and
starts the built-in load generator. See [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md)
for details.

-

## Layout

- `kind/cluster.yaml` — single-node cluster `eshop`, maps NodePort 30080 → host 8080
- `scripts/setup.sh` — create cluster + build/load images + deploy (idempotent)
- `scripts/traffic.sh` — send demo traffic to the storefront
- `scripts/agent.sh` — apply/status/logs/restart/down for the Elastic Agent
- `scripts/apm-server.sh` — apply/status/logs/restart/down for the APM Server
- `services/frontend` — storefront (port 3000), calls the backend over HTTP
- `services/backend` — product catalog API (port 3000, Express, in-memory data)
- `k8s/` — namespace, APM secret template, deployments, services, loadgen
- `k8s/common/` — the shared Elasticsearch credentials template
- `k8s/apm-server/` — APM Server ConfigMap, Deployment and Service
- `k8s/elastic-agent/` — Elastic Agent standalone + kube-state-metrics

Neither service calls `apm.start()` — both are started with
`node -r elastic-apm-node/start.js server.js` and configured entirely through
environment variables.

---

Prefer to run each command yourself, or need to debug a step?
[MANUAL.md](MANUAL.md) has the full step-by-step version — the scripts run
exactly those commands.
