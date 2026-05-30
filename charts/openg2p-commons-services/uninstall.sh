#!/usr/bin/env bash
# Cleanly uninstall openg2p-commons application services.
# NOTE: This does NOT remove infrastructure (PostgreSQL, Kafka, etc.).
# To remove infrastructure, run uninstall-base.sh from openg2p-commons-base.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <namespace> <release-name>"
  echo "  namespace    : Kubernetes namespace"
  echo "  release-name : Helm release name"
  echo ""
  echo "  This will remove the application services Helm release and"
  echo "  clean up orphaned Jobs. Infrastructure (databases, message"
  echo "  queues, secrets, PVCs) is NOT affected."
  echo ""
  echo "  To remove infrastructure, run uninstall-base.sh separately."
  exit 1
fi

NAMESPACE="$1"
RELEASE="$2"

echo ""
echo "=== Uninstalling application services '$RELEASE' from namespace '$NAMESPACE' ==="

# 1. Uninstall the Helm release
echo ""
echo "--- Helm uninstall ---"
if helm status "$RELEASE" -n "$NAMESPACE" &>/dev/null; then
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait || true
  echo "Helm release '$RELEASE' uninstalled."
else
  echo "Helm release '$RELEASE' not found. Skipping."
fi

# 2. Clean up orphaned Jobs left behind by subcharts
echo ""
echo "--- Cleaning up orphaned Jobs ---"
APP_JOBS=(
  "${RELEASE}-esignet-postgres-init"
  "${RELEASE}-mock-identity-system-postgres-init"
  "${RELEASE}-keymanager-postgres-init"
  "${RELEASE}-keymanager-keygen"
  "${RELEASE}-master-data-postgres-init"
  "master-data-postgres-init"
  "${RELEASE}-superset-init-db"
)
for name in "${APP_JOBS[@]}"; do
  kubectl delete job "$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  kubectl delete serviceaccount "$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null
done
echo "Orphaned Jobs cleaned up."

echo ""
echo "=== Application services uninstall complete ==="
echo ""
echo "NOTE: Infrastructure (databases, secrets, PVCs) was NOT removed."
echo "      To fully clean up, run uninstall-base.sh from openg2p-commons-base."
