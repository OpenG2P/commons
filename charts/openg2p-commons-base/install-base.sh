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

# Enforce the release name. Other releases break cross-chart references
# (commons-services expects 'commons' as the base release name).
if [ "$RELEASE" != "commons" ]; then
  echo "ERROR: release-name must be 'commons' (got '$RELEASE')."
  echo "Cross-chart references (postgres host, keycloak admin secret, etc.)"
  echo "assume the base release is named 'commons'. Use:"
  echo "  $0 $NAMESPACE commons $BASE_DOMAIN"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure namespace exists
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

echo ""
echo "=== Updating Helm dependencies (clean pull) ==="
rm -rf "$SCRIPT_DIR/charts/"*.tgz "$SCRIPT_DIR/Chart.lock" 2>/dev/null || true
helm dependency update "$SCRIPT_DIR"

echo ""
echo "=== Pre-flight check: resource name lengths ==="
# Kubernetes resource names must be <= 63 chars (DNS-1123 label).
LONG_NAMES=$(helm template "$RELEASE" "$SCRIPT_DIR" \
  --set global.baseDomain="$BASE_DOMAIN" \
  -n "$NAMESPACE" 2>/dev/null \
  | grep -E '^  name: ' | sed 's/^  name: //' | sed 's/"//g' \
  | awk '{ if (length($0) > 63) print length($0), $0 }')
if [ -n "$LONG_NAMES" ]; then
  echo "ERROR: Resource names exceed Kubernetes 63-char limit:"
  echo "$LONG_NAMES"
  echo "Shorten the corresponding nameOverride in values.yaml."
  exit 1
fi
echo "All resource names within 63-char limit."

# If external PostgreSQL is requested (postgresql.enabled=false in any --set arg),
# verify the superuser secret exists before install. Helm cannot create it on the fly.
if echo "$@" | grep -qE 'postgresql\.enabled=false'; then
  EXT_PG_SECRET=$(echo "$@" | grep -oE 'global\.postgresqlSecret=[^ ]+' | cut -d= -f2)
  EXT_PG_SECRET="${EXT_PG_SECRET:-${RELEASE}-postgresql}"
  echo ""
  echo "=== Pre-flight check: external PostgreSQL secret ==="
  if ! kubectl get secret "$EXT_PG_SECRET" -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: External PostgreSQL secret '$EXT_PG_SECRET' not found in namespace '$NAMESPACE'."
    echo "Pre-create it before installing:"
    echo "  kubectl create secret generic $EXT_PG_SECRET -n $NAMESPACE \\"
    echo "    --from-literal=postgres-password='<superuser-password>'"
    exit 1
  fi
  echo "Found external PostgreSQL secret '$EXT_PG_SECRET'."
fi

echo ""
echo "=== Installing base infrastructure '$RELEASE' in namespace '$NAMESPACE' ==="
echo "    Domain: $BASE_DOMAIN | Keycloak: https://keycloak.$BASE_DOMAIN"
echo ""

helm upgrade --install "$RELEASE" "$SCRIPT_DIR" \
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
