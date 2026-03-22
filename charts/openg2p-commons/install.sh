#!/usr/bin/env bash
# Install openg2p-commons Helm chart.
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "Usage: $0 <namespace> <release-name> <base-domain> <keycloak-url> [extra-helm-args...]"
  echo "  namespace    : Kubernetes namespace"
  echo "  release-name : Helm release name"
  echo "  base-domain  : Base domain (e.g. mysandbox.openg2p.org)"
  echo "  keycloak-url : Full Keycloak base URL (e.g. https://keycloak.openg2p.org)"
  echo "  extra args   : Any additional --set or flags passed to helm install"
  echo ""
  echo "Example:"
  echo "  $0 trial commons mysandbox.openg2p.org https://keycloak.openg2p.org"
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"
BASE_DOMAIN="$3"
KEYCLOAK_URL="$4"
shift 4

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Installing '$RELEASE' in namespace '$NAMESPACE' (domain: $BASE_DOMAIN, keycloak: $KEYCLOAK_URL) ==="

helm install "$RELEASE" "$SCRIPT_DIR" \
  -n "$NAMESPACE" --create-namespace \
  --set global.baseDomain="$BASE_DOMAIN" \
  --set global.keycloakBaseUrl="$KEYCLOAK_URL" \
  "$@" \
  --wait --timeout 15m

echo ""
echo "=== Install complete ==="
