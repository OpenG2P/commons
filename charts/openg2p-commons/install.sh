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

# Ensure namespace exists
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

# Check if keycloak-client-manager secret exists; if not, prompt for credentials
if ! kubectl get secret keycloak-client-manager -n "$NAMESPACE" &>/dev/null; then
  echo ""
  echo "Keycloak client-manager secret not found in namespace '$NAMESPACE'."
  echo "This secret is required for keycloak-init to create OIDC clients."
  echo "The user must have roles: manage-clients, query-clients, view-clients in Keycloak master realm."
  echo ""
  read -rp "Keycloak client-manager username [client-manager@openg2p.org]: " KC_USER
  KC_USER="${KC_USER:-client-manager@openg2p.org}"
  read -rsp "Keycloak client-manager password: " KC_PASS
  echo ""

  if [ -z "$KC_PASS" ]; then
    echo "Error: Password cannot be empty."
    exit 1
  fi

  kubectl create secret generic keycloak-client-manager \
    -n "$NAMESPACE" \
    --from-literal=keycloak-client-manager-password="$KC_PASS"
  echo "Secret 'keycloak-client-manager' created in namespace '$NAMESPACE'."

  # Pass the username to helm (password is now in the secret)
  EXTRA_KC_ARGS=(--set "keycloak-init.keycloak.user=$KC_USER")
else
  echo "Secret 'keycloak-client-manager' already exists in namespace '$NAMESPACE'. Skipping."
  EXTRA_KC_ARGS=()
fi

echo ""
echo "=== Installing '$RELEASE' in namespace '$NAMESPACE' (domain: $BASE_DOMAIN, keycloak: $KEYCLOAK_URL) ==="

helm install "$RELEASE" "$SCRIPT_DIR" \
  -n "$NAMESPACE" \
  --set global.baseDomain="$BASE_DOMAIN" \
  --set global.keycloakBaseUrl="$KEYCLOAK_URL" \
  "${EXTRA_KC_ARGS[@]}" \
  "$@" \
  --wait --timeout 15m

echo ""
echo "=== Install complete ==="
