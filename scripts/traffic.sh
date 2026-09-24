#!/usr/bin/env bash
# Generates demo traffic against the frontend (runbook step 6).
# The frontend is a NodePort mapped to host port 8080 by kind/cluster.yaml,
# so no port-forward is needed.
# Usage: ./scripts/traffic.sh [requests]   (default 50)
set -euo pipefail

CLUSTER=${CLUSTER:-eshop}
NAMESPACE=${NAMESPACE:-ecs-eshop}
CONTEXT=${CONTEXT:-kind-$CLUSTER}
URL=${URL:-http://localhost:8080}
REQUESTS=${1:-50}

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

kubectl --context "$CONTEXT" -n "$NAMESPACE" \
  rollout status deployment/ecs-eshop-frontend --timeout=120s

# Wait for the NodePort to accept connections before hammering it.
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "$URL/healthz"; then break; fi
  sleep 1
done
curl -sf -o /dev/null "$URL/healthz" || {
  echo "$URL never became ready - is the cluster up? (./scripts/setup.sh)" >&2
  exit 1
}

echo "==> Sending $REQUESTS request pairs to $URL"
for _ in $(seq 1 "$REQUESTS"); do
  curl -s -o /dev/null "$URL/"
  curl -s -o /dev/null "$URL/api/products"
done

echo "Done. Each request is one distributed trace across ecs-eshop-frontend and ecs-eshop-backend."
