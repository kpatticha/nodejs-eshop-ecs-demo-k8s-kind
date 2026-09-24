#!/usr/bin/env bash
# APM Server, the in-cluster ingest endpoint for the two Node.js services
# (see APM_SERVER.md).
#
# It runs in kube-system rather than ecs-eshop so it can share the Secret
# `elasticsearch-credentials` with the Elastic Agent DaemonSet - Secrets are
# namespace-scoped, so that is the only way both read the same object.
#
# Usage: ./scripts/apm-server.sh <apply|status|logs|restart|down>
set -euo pipefail

CLUSTER=${CLUSTER:-eshop}
CONTEXT=${CONTEXT:-kind-$CLUSTER}
ES_SECRET=k8s/common/elasticsearch-secret.yaml
APM_SECRET=k8s/apm-secret.yaml

cd "$(dirname "$0")/.."

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

kube() { kubectl --context "$CONTEXT" "$@"; }
kubesys() { kube -n kube-system "$@"; }

require_es_secret() {
  [ -f "$ES_SECRET" ] && return
  echo "$ES_SECRET not found." >&2
  echo "Copy k8s/common/elasticsearch-secret.example.yaml to it and fill in es-host, username and password." >&2
  exit 1
}

# The secret token is an internal shared secret between the services and this
# server, not an external credential, so the placeholder is usable as-is.
apply_apm_secret() {
  if [ -f "$APM_SECRET" ]; then
    kube apply -f "$APM_SECRET"
  else
    echo "$APM_SECRET not found - applying the placeholder from k8s/apm-secret.example.yaml"
    kube apply -f k8s/apm-secret.example.yaml
  fi
}

case "${1:-}" in
  apply)
    require_es_secret
    # The apm-credentials Secret spans both namespaces, so ecs-eshop has to
    # exist even if the services were never deployed.
    kube apply -f k8s/namespace.yaml
    kube apply -f "$ES_SECRET"
    apply_apm_secret
    kube apply -f k8s/apm-server/apm-server.yaml
    kubesys rollout status deploy/apm-server --timeout=120s
    ;;
  status)
    kubesys get pods -o wide -l 'app.kubernetes.io/name=apm-server'
    ;;
  logs)
    kubesys logs deploy/apm-server --tail=100 -f
    ;;
  restart)
    # Two reasons a restart is needed: env vars sourced from a Secret are read
    # at container start, and the config is a subPath ConfigMap mount, which
    # kubelet never refreshes in place. Re-apply both, then roll.
    require_es_secret
    kube apply -f "$ES_SECRET"
    apply_apm_secret
    kube apply -f k8s/apm-server/apm-server.yaml
    kubesys rollout restart deploy/apm-server
    kubesys rollout status deploy/apm-server --timeout=120s
    ;;
  down)
    kube delete -f k8s/apm-server/apm-server.yaml --ignore-not-found
    kubesys delete secret apm-credentials --ignore-not-found
    # `elasticsearch-credentials` is deliberately left alone: the Elastic Agent
    # shares it. Remove it with ./scripts/agent.sh es-secret-down.
    ;;
  *)
    echo "Usage: ./scripts/apm-server.sh <apply|status|logs|restart|down>" >&2
    exit 1
    ;;
esac
