#!/usr/bin/env bash
# Elastic Agent standalone + kube-state-metrics, the opt-in Kubernetes
# monitoring side of the demo (see K8S_MONITORING.md).
#
# Usage: ./scripts/agent.sh <apply|status|logs|restart|down|es-secret-down>
set -euo pipefail

CLUSTER=${CLUSTER:-eshop}
CONTEXT=${CONTEXT:-kind-$CLUSTER}
# Elasticsearch credentials, shared with the APM Server (k8s/apm-server/).
SECRET=k8s/common/elasticsearch-secret.yaml

cd "$(dirname "$0")/.."

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

kube() { kubectl --context "$CONTEXT" "$@"; }
kubesys() { kube -n kube-system "$@"; }

require_secret() {
  [ -f "$SECRET" ] && return
  echo "$SECRET not found." >&2
  echo "Copy k8s/common/elasticsearch-secret.example.yaml to it and fill in es-host, username and password." >&2
  exit 1
}

case "${1:-}" in
  apply)
    require_secret
    # A DaemonSet applied from outside this repo has a different pod selector,
    # and selectors are immutable - it cannot be updated in place.
    if kubesys get ds elastic-agent-standalone >/dev/null 2>&1 && \
       [ -n "$(kubesys get ds elastic-agent-standalone -o jsonpath='{.spec.selector.matchLabels.app}')" ]; then
      echo "An elastic-agent-standalone DaemonSet from a different source is already installed." >&2
      echo "Remove it first: ./scripts/agent.sh down" >&2
      exit 1
    fi
    kube apply -f k8s/elastic-agent/kube-state-metrics.yaml
    kube apply -f "$SECRET"
    kube apply -f k8s/elastic-agent/elastic-agent-standalone.yaml
    kubesys rollout status deploy/kube-state-metrics --timeout=120s
    kubesys rollout status ds/elastic-agent-standalone --timeout=180s
    ;;
  status)
    kubesys get pods -o wide \
      -l 'app.kubernetes.io/name in (elastic-agent-standalone,kube-state-metrics)'
    ;;
  logs)
    kubesys logs ds/elastic-agent-standalone --tail=100 -f
    ;;
  restart)
    # Env vars sourced from a Secret are not picked up without a restart.
    require_secret
    kube apply -f "$SECRET"
    kubesys rollout restart ds/elastic-agent-standalone
    kubesys rollout status ds/elastic-agent-standalone --timeout=180s
    ;;
  down)
    kube delete -f k8s/elastic-agent/elastic-agent-standalone.yaml --ignore-not-found
    kube delete -f k8s/elastic-agent/kube-state-metrics.yaml --ignore-not-found
    # The Secret is deliberately left in place: the APM Server shares it, and
    # deleting it here would break a running apm-server at its next restart.
    echo "Left Secret elasticsearch-credentials in place (shared with the APM Server)."
    echo "Remove it with: ./scripts/agent.sh es-secret-down"
    ;;
  es-secret-down)
    # Only do this once nothing else needs the credentials.
    kubesys delete secret elasticsearch-credentials --ignore-not-found
    ;;
  *)
    echo "Usage: ./scripts/agent.sh <apply|status|logs|restart|down|es-secret-down>" >&2
    exit 1
    ;;
esac
