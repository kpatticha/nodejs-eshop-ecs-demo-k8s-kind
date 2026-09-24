#!/usr/bin/env bash
# Creates the kind cluster and builds/deploys the demo services (runbook steps 3 & 4).
# Safe to re-run: reuses an existing cluster, rebuilds and redeploys the apps.
set -euo pipefail

CLUSTER=${CLUSTER:-eshop}
NAMESPACE=${NAMESPACE:-ecs-eshop}
CONTEXT=${CONTEXT:-kind-$CLUSTER}
TAG=${TAG:-dev}
BACKEND_IMG="ecs-eshop-backend:$TAG"
FRONTEND_IMG="ecs-eshop-frontend:$TAG"

cd "$(dirname "$0")/.."

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done

# Every kubectl call is pinned to this context, so another current-context
# cannot make the manifests land in the wrong cluster.
kube() { kubectl --context "$CONTEXT" "$@"; }

echo "==> Cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "cluster '$CLUSTER' already exists, reusing it"
else
  kind create cluster --name "$CLUSTER" --config kind/cluster.yaml --wait 120s
fi
kube get nodes

echo "==> Build images"
docker build -t "$BACKEND_IMG" services/backend
docker build -t "$FRONTEND_IMG" services/frontend
kind load docker-image "$BACKEND_IMG" "$FRONTEND_IMG" --name "$CLUSTER"

echo "==> Deploy"
kube apply -f k8s/namespace.yaml
if [ -f k8s/apm-secret.yaml ]; then
  kube apply -f k8s/apm-secret.yaml
else
  echo "k8s/apm-secret.yaml not found - applying the placeholder from k8s/apm-secret.example.yaml"
  echo "(it points the services at the in-cluster APM Server, see APM_SERVER.md)"
  kube apply -f k8s/apm-secret.example.yaml
fi
kube apply -f k8s/backend.yaml -f k8s/frontend.yaml -f k8s/loadgen.yaml

# Pick up freshly loaded images and secret values when the deployments already exist.
kube -n "$NAMESPACE" rollout restart deployment ecs-eshop-backend ecs-eshop-frontend
kube -n "$NAMESPACE" rollout status deployment/ecs-eshop-backend --timeout=120s
kube -n "$NAMESPACE" rollout status deployment/ecs-eshop-frontend --timeout=120s
kube -n "$NAMESPACE" rollout status deployment/ecs-loadgen --timeout=120s

kube -n "$NAMESPACE" get pods -o wide

echo ""
echo "Storefront: http://localhost:8080"
echo ""
echo "The services are configured to send APM data to the in-cluster APM Server."
echo "If it is not deployed yet, run ./scripts/apm-server.sh apply - until then"
echo "the APM agents log connection errors. The storefront is unaffected."
