#!/usr/bin/env bash
# Cleanly uninstall openg2p-commons: chart, hooks, secrets, PVCs, and released PVs.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <namespace> <release-name>"
  echo "  namespace    : Kubernetes namespace"
  echo "  release-name : Helm release name"
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"

echo "=== Uninstalling release '$RELEASE' from namespace '$NAMESPACE' ==="

# 1. Uninstall the Helm release
echo ""
echo "--- Helm uninstall ---"
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait || true
  echo "Helm release '$RELEASE' uninstalled."
else
  echo "Helm release '$RELEASE' not found. Skipping."
fi

# 2. Delete orphaned hook resources (Jobs, ServiceAccounts) left behind by Helm hooks
echo ""
echo "--- Cleaning up hook Jobs and ServiceAccounts ---"
kubectl delete jobs -n "$NAMESPACE" -l app.kubernetes.io/managed-by=Helm --ignore-not-found
# Also delete known hook jobs/SAs that may not have labels
HOOK_RESOURCES=(
  "${RELEASE}-postgres-init"
  "${RELEASE}-esignet-postgres-init"
  "${RELEASE}-mock-identity-system-postgres-init"
  "${RELEASE}-keymanager-postgres-init"
  "${RELEASE}-keymanager-keygen"
  "${RELEASE}-master-data-postgres-init"
  "${RELEASE}-keycloak-init"
)
for name in "${HOOK_RESOURCES[@]}"; do
  kubectl delete job "$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  kubectl delete serviceaccount "$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  kubectl delete configmap "$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
done
# keycloak-init jobs include revision number in name (e.g. commons-keycloak-init-1)
kubectl delete jobs -n "$NAMESPACE" -l app.kubernetes.io/name=keycloak-init --ignore-not-found 2>/dev/null
echo "Hook resources cleaned up."

# 3. Delete Secrets in the namespace, preserving Keycloak client secrets
#    (they have helm.sh/resource-policy=keep because Keycloak clients persist
#    on the Keycloak server and the secrets must stay in sync)
echo ""
echo "--- Deleting Secrets in namespace '$NAMESPACE' (preserving Keycloak client secrets) ---"
KEYCLOAK_SECRETS=$(kubectl get secrets -n "$NAMESPACE" -o jsonpath='{range .items[?(@.metadata.annotations.helm\.sh/resource-policy=="keep")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$KEYCLOAK_SECRETS" ]; then
  echo "Preserving secrets with resource-policy=keep:"
  echo "$KEYCLOAK_SECRETS" | sed 's/^/  /'
fi
# Delete all secrets EXCEPT those with resource-policy=keep
kubectl get secrets -n "$NAMESPACE" -o json | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    ann = item.get('metadata', {}).get('annotations', {}) or {}
    if ann.get('helm.sh/resource-policy') != 'keep':
        print(item['metadata']['name'])
" | while read -r secret_name; do
  kubectl delete secret "$secret_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
done
echo "Secrets deleted (Keycloak client secrets preserved)."

# 4. Delete all PVCs in the namespace, and collect bound PV names first
echo ""
echo "--- Deleting PVCs in namespace '$NAMESPACE' ---"
PV_NAMES=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found
echo "PVCs deleted."

# 5. Delete PVs that were bound to the above PVCs and are now in Released state
echo ""
echo "--- Cleaning up Released PVs ---"
if [ -n "$PV_NAMES" ]; then
  # Wait briefly for PV status to update after PVC deletion
  sleep 3
  for pv in $PV_NAMES; do
    PV_STATUS=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$PV_STATUS" = "Released" ]; then
      echo "Deleting PV '$pv' (Released)"
      kubectl delete pv "$pv" --ignore-not-found
    elif [ -n "$PV_STATUS" ]; then
      echo "Skipping PV '$pv' (status: $PV_STATUS)"
    fi
  done
else
  echo "No PVs to clean up."
fi

echo ""
echo "=== Uninstall complete ==="
