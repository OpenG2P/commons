#!/usr/bin/env bash
# Install openg2p-commons Helm chart (application services layer).
# PREREQUISITE: openg2p-commons-base must be installed first in the same namespace.
set -euo pipefail

if [ $# -lt 5 ]; then
  echo "Usage: $0 <namespace> <release-name> <base-release-name> <base-domain> <keycloak-url> [extra-helm-args...]"
  echo "  namespace          : Kubernetes namespace (must match base chart namespace)"
  echo "  release-name       : Helm release name for apps (e.g. commons)"
  echo "  base-release-name  : Release name used for openg2p-commons-base (e.g. commons-base)"
  echo "  base-domain        : Base domain (e.g. mysandbox.openg2p.org)"
  echo "  keycloak-url       : Full Keycloak base URL (e.g. https://keycloak.openg2p.org)"
  echo "  extra args         : Any additional --set or flags passed to helm install"
  echo ""
  echo "PREREQUISITE: openg2p-commons-base must be installed in the same namespace first."
  echo ""
  echo "Example:"
  echo "  $0 trial commons commons-base mysandbox.openg2p.org https://keycloak.openg2p.org"
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"
BASE_RELEASE="$3"
BASE_DOMAIN="$4"
KEYCLOAK_URL="$5"
shift 5

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verify namespace exists (should already exist from base install)
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Namespace '$NAMESPACE' does not exist. Install openg2p-commons-base first."
  exit 1
fi

# Verify base chart is installed
if ! helm status "$BASE_RELEASE" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Base chart release '$BASE_RELEASE' not found in namespace '$NAMESPACE'."
  echo "       Install openg2p-commons-base first using install-base.sh."
  exit 1
fi

echo ""
echo "=== Installing application services '$RELEASE' in namespace '$NAMESPACE' ==="
echo "    Base release: $BASE_RELEASE | Domain: $BASE_DOMAIN | Keycloak: $KEYCLOAK_URL"
echo ""

# Derive infrastructure service names from the base release name
helm install "$RELEASE" "$SCRIPT_DIR" \
  -n "$NAMESPACE" \
  --set global.baseDomain="$BASE_DOMAIN" \
  --set global.keycloakBaseUrl="$KEYCLOAK_URL" \
  --set global.postgresqlHost="${BASE_RELEASE}-postgresql" \
  --set global.redisInstallationName="${BASE_RELEASE}-redis" \
  --set global.redisAuthInstallationName="${BASE_RELEASE}-redis-auth" \
  --set global.minioInstallationName="${BASE_RELEASE}-minio" \
  --set global.mailInstallationName="${BASE_RELEASE}-mail" \
  --set global.kafkaInstallationName="${BASE_RELEASE}-kafka" \
  --set global.softhsmInstallationName="${BASE_RELEASE}-softhsm" \
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
echo "=== Application services install complete ==="
