#!/usr/bin/env bash
# Install openg2p-commons-base Helm chart (infrastructure layer).
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <namespace> <release-name> <base-domain> [extra-helm-args...]"
  echo "  namespace          : Kubernetes namespace"
  echo "  release-name       : Helm release name (e.g. commons)"
  echo "  base-domain        : Base domain (e.g. trial.openg2p.org)"
  echo "  extra args         : Any additional --set or flags passed to helm install"
  echo ""
  echo "Example:"
  echo "  $0 trial commons trial.openg2p.org"
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"
BASE_DOMAIN="$3"
shift 3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure namespace exists
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

echo ""
echo "=== Installing base infrastructure '$RELEASE' in namespace '$NAMESPACE' ==="
echo "    Domain: $BASE_DOMAIN | Keycloak: https://keycloak.$BASE_DOMAIN"
echo ""

helm install "$RELEASE" "$SCRIPT_DIR" \
  -n "$NAMESPACE" \
  --set global.baseDomain="$BASE_DOMAIN" \
  --timeout 20m \
  "$@"

echo ""
echo "=== Helm install submitted. Waiting for infrastructure to be ready... ==="

# Poll until PostgreSQL and other statefulsets/deployments are ready
TIMEOUT=900  # 15 minutes
INTERVAL=15
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  NOT_READY=""

  # Check deployments
  DEPLOY_NOT_READY=$(kubectl get deployments -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.availableReplicas != .status.replicas) | .metadata.name' 2>/dev/null || true)

  # Check statefulsets
  STS_NOT_READY=$(kubectl get statefulsets -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.readyReplicas != .status.replicas) | .metadata.name' 2>/dev/null || true)

  NOT_READY="${DEPLOY_NOT_READY} ${STS_NOT_READY}"
  NOT_READY=$(echo "$NOT_READY" | xargs)  # trim whitespace

  if [ -z "$NOT_READY" ]; then
    echo ""
    echo "=== All infrastructure resources are ready ==="
    break
  fi

  echo "Waiting for: ${NOT_READY}... (${ELAPSED}s/${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo ""
  echo "WARNING: Timed out waiting for resources. Check status:"
  kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running 2>/dev/null
  exit 1
fi

echo ""
echo "=== Base infrastructure install complete ==="
