#!/usr/bin/env bash
# Cleanly uninstall openg2p-commons: chart, hooks, secrets, PVCs, and released PVs.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <namespace> <release-name>"
  echo "  namespace    : Kubernetes namespace"
  echo "  release-name : Helm release name"
  echo ""
  echo "  WARNING: This script will PERMANENTLY DELETE:"
  echo "    - The Helm release and all its resources"
  echo "    - ALL Secrets in the namespace (including Keycloak client secrets)"
  echo "    - ALL PVCs in the namespace"
  echo "    - ALL PVs that were bound to those PVCs"
  echo "    - All orphaned hook Jobs and ServiceAccounts"
  echo ""
  echo "  This action is IRREVERSIBLE. Keycloak client secrets will need to be"
  echo "  re-synced from the Keycloak server on the next install."
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  WARNING: DESTRUCTIVE OPERATION                                ║"
echo "║                                                                ║"
echo "║  This will PERMANENTLY DELETE all resources in namespace       ║"
echo "║  '$NAMESPACE' including:                                       "
echo "║    - Helm release '$RELEASE'                                   "
echo "║    - ALL Secrets (including Keycloak client secrets)           ║"
echo "║    - ALL PVCs and their associated PVs                        ║"
echo "║                                                                ║"
echo "║  This action is IRREVERSIBLE.                                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
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

# 3. Delete ALL Secrets in the namespace (including Keycloak client secrets)
echo ""
echo "--- Deleting ALL Secrets in namespace '$NAMESPACE' ---"
kubectl delete secrets -n "$NAMESPACE" --all --ignore-not-found
echo "All secrets deleted."

# 4. Delete all PVCs in the namespace, and collect bound PV names first
echo ""
echo "--- Deleting PVCs in namespace '$NAMESPACE' ---"
PV_NAMES=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found
echo "PVCs deleted."

# 5. Delete PVs that were bound to the above PVCs
echo ""
echo "--- Cleaning up PVs ---"
if [ -n "$PV_NAMES" ]; then
  # Wait for PV status to update after PVC deletion
  sleep 5
  for pv in $PV_NAMES; do
    PV_STATUS=$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ -z "$PV_STATUS" ]; then
      echo "PV '$pv' already gone."
    else
      echo "Deleting PV '$pv' (status: $PV_STATUS)"
      kubectl delete pv "$pv" --ignore-not-found
    fi
  done
else
  echo "No PVs to clean up."
fi

echo ""
echo "=== Uninstall complete ==="
