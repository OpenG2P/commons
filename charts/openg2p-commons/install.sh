#!/usr/bin/env bash
# Install openg2p-commons Helm chart.
set -euo pipefail

if [ $# -lt 6 ]; then
  echo "Usage: $0 <namespace> <release-name> <base-domain> <keycloak-url> <keycloak-username> <keycloak-password> [extra-helm-args...]"
  echo "  namespace          : Kubernetes namespace"
  echo "  release-name       : Helm release name"
  echo "  base-domain        : Base domain (e.g. mysandbox.openg2p.org)"
  echo "  keycloak-url       : Full Keycloak base URL (e.g. https://keycloak.openg2p.org)"
  echo "  keycloak-username  : Keycloak client-manager username (must have manage-clients, query-clients, view-clients roles in master realm)"
  echo "  keycloak-password  : Keycloak client-manager password"
  echo "  extra args         : Any additional --set or flags passed to helm install"
  echo ""
  echo "Example:"
  echo "  $0 trial commons mysandbox.openg2p.org https://keycloak.openg2p.org client-manager@openg2p.org mypassword"
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"
BASE_DOMAIN="$3"
KEYCLOAK_URL="$4"
KC_USER="$5"
KC_PASS="$6"
shift 6

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure namespace exists
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

# Create or update keycloak-client-manager secret
if ! kubectl get secret keycloak-client-manager -n "$NAMESPACE" &>/dev/null; then
  kubectl create secret generic keycloak-client-manager \
    -n "$NAMESPACE" \
    --from-literal=keycloak-client-manager-password="$KC_PASS"
  echo "Secret 'keycloak-client-manager' created in namespace '$NAMESPACE'."
else
  echo "Secret 'keycloak-client-manager' already exists in namespace '$NAMESPACE'. Skipping."
fi

echo ""
echo "=== Installing '$RELEASE' in namespace '$NAMESPACE' (domain: $BASE_DOMAIN, keycloak: $KEYCLOAK_URL) ==="

helm install "$RELEASE" "$SCRIPT_DIR" \
  -n "$NAMESPACE" \
  --set global.baseDomain="$BASE_DOMAIN" \
  --set global.keycloakBaseUrl="$KEYCLOAK_URL" \
  --set "keycloak-init.keycloak.url=$KEYCLOAK_URL" \
  --set "keycloak-init.keycloak.user=$KC_USER" \
  --timeout 20m \
  "$@"

echo ""
echo "=== Helm install submitted. Waiting for resources to be ready... ==="

# Poll until all deployments are available or timeout
TIMEOUT=900  # 15 minutes
INTERVAL=15
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  NOT_READY=$(kubectl get deployments -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.availableReplicas != .status.replicas) | .metadata.name' 2>/dev/null)

  if [ -z "$NOT_READY" ]; then
    echo ""
    echo "=== All deployments are ready ==="
    break
  fi

  echo "Waiting for deployments: $(echo "$NOT_READY" | tr '\n' ' ')... (${ELAPSED}s/${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo ""
  echo "WARNING: Timed out waiting for deployments. Check status:"
  kubectl get pods -n "$NAMESPACE" --field-selector=status.phase!=Running 2>/dev/null
  exit 1
fi

echo ""
echo "=== Install complete ==="
