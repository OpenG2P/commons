#!/usr/bin/env bash
#
# uninstall-base.sh  (openg2p-commons-base)
# -----------------------------------------
# Cleanly uninstall the commons-base infrastructure release and everything it
# leaves behind. Because base OWNS the embedded PostgreSQL, deleting its PVC
# destroys ALL databases (base's own AND the services DBs that live inside it),
# so there is no per-database psql drop step — the data goes with the volume.
#
#   1. helm uninstall <release>              (helm-owned workloads/secrets/cm)
#   2. Delete leftover Jobs + their Pods     (postgres-init / keycloak-init /
#                                             client-secrets-sync hook Jobs use
#                                             hook-delete-policy: before-hook-creation
#                                             and are NOT removed by helm uninstall)
#   3. Delete orphaned hook ServiceAccounts  (commons-postgres-init,
#                                             + RBAC                 commons-keycloak-init, … — no
#                                             ownership annotation, so they survive AND
#                                             block the next install with
#                                             "cannot be imported into the current release")
#   4. Sweep Secrets / ConfigMaps            (incl. resource-policy: keep per-DB
#                                             secrets: keycloak-db-user, superset-db-user,
#                                             odk-db-user, keymgr-db-user, mockid-db-user,
#                                             esignet-db-user)
#   5. Delete PVCs by label                  (postgresql, kafka, minio, redis,
#                                             redis-auth, softhsm) — this is what actually
#                                             drops every database
#   6. Delete PVs still bound to those PVCs
#
# Uninstall commons-services FIRST (its uninstall.sh) so its DB roles/secrets are
# dropped cleanly; then run this. (If you skip that and just run this, the services
# databases still vanish with the PostgreSQL PVC, but the services *-db-user secrets
# in the namespace would be left dangling — this script's label sweep only removes
# base's own labeled secrets.)
#
# Requires: kubectl (cluster admin), helm, bash 4+, jq.
#
# USAGE:
#   ./uninstall-base.sh --namespace <ns> [options]
#     --namespace, -n <ns>   (required) Kubernetes namespace
#     --release <name>       Helm release name   (default: commons)
#     --keep-pvs             delete PVCs but not the PVs behind them
#     --dry-run              print actions, change nothing
#     --yes, -y              skip the interactive confirmation
#
# EXAMPLES:
#   ./uninstall-base.sh -n trial --dry-run
#   ./uninstall-base.sh -n trial
#   ./uninstall-base.sh -n trial --yes

set -euo pipefail

# ---------- defaults ----------
RELEASE="commons"
NAMESPACE=""
KEEP_PVS=false
DRY_RUN=false
ASSUME_YES=false

# ---------- cli ----------
usage() { sed -n '2,45p' "$0"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)       RELEASE="$2";     shift 2 ;;
    --namespace|-n)  NAMESPACE="$2";   shift 2 ;;
    --keep-pvs)      KEEP_PVS=true;    shift ;;
    --dry-run)       DRY_RUN=true;     shift ;;
    --yes|-y)        ASSUME_YES=true;  shift ;;
    -h|--help)       usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { echo "ERROR: --namespace is required"; usage; }
LABEL="app.kubernetes.io/instance=$RELEASE"

# ---------- helpers ----------
_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
_green() { printf "\033[32m%s\033[0m\n" "$*"; }
_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

run() {
  echo "  \$ $*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@" || _yellow "  (command returned non-zero — continuing)"
  fi
}

# ---------- pre-flight ----------
_blue "==> Pre-flight checks"
command -v kubectl >/dev/null || { _red "kubectl not found"; exit 1; }
command -v helm    >/dev/null || { _red "helm not found";    exit 1; }
command -v jq      >/dev/null || { _red "jq not found";      exit 1; }

if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  NAMESPACE_EXISTS=true;  _green "  Namespace '$NAMESPACE' exists"
else
  NAMESPACE_EXISTS=false; _yellow "  Namespace '$NAMESPACE' does not exist — k8s cleanup skipped"
fi

if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  HELM_RELEASE_EXISTS=true;  _green "  Helm release '$RELEASE' found"
else
  HELM_RELEASE_EXISTS=false; _yellow "  Helm release '$RELEASE' not found — skipping helm uninstall"
fi

# ---------- blast radius ----------
_blue "==> Resources to be deleted (label $LABEL)"
echo
echo "Helm release: $RELEASE (ns: $NAMESPACE)"
echo
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  for kind in job secret configmap pvc serviceaccount; do
    echo "${kind}s:"
    kubectl -n "$NAMESPACE" get "$kind" -l "$LABEL" --no-headers 2>/dev/null \
      | awk '{print "  - " $1}' || echo "  (none)"
  done
fi
echo
_red "NOTE: deleting the PostgreSQL PVC destroys EVERY database in this environment"
_red "      (base AND services). This is IRREVERSIBLE."
echo

# ---------- confirmation ----------
[[ "$DRY_RUN" == true ]] && _yellow "DRY-RUN: no changes will be made."
if [[ "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
  _red "This is destructive. Type the release name ('$RELEASE') to confirm:"
  read -r CONFIRM
  [[ "$CONFIRM" != "$RELEASE" ]] && { _red "Confirmation did not match. Aborting."; exit 1; }
fi

# ========== STEP 1: helm uninstall ==========
_blue "==> [1/6] Helm uninstall"
if [[ "$HELM_RELEASE_EXISTS" == true ]]; then
  run "helm uninstall '$RELEASE' -n '$NAMESPACE' --wait --timeout 10m || true"
else
  echo "  (skipped — release not present)"
fi

# ========== STEP 2: leftover Jobs + Pods ==========
_blue "==> [2/6] Delete leftover Jobs and their Pods"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete job -l '$LABEL' --ignore-not-found --wait=true --timeout=2m"
  run "kubectl -n '$NAMESPACE' delete pod -l '$LABEL' --ignore-not-found --field-selector=status.phase!=Running"
else
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 3: orphaned hook ServiceAccounts + RBAC ==========
_blue "==> [3/6] Delete orphaned ServiceAccounts / RBAC"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete serviceaccount -l '$LABEL' --ignore-not-found"
  run "kubectl -n '$NAMESPACE' delete role,rolebinding -l '$LABEL' --ignore-not-found"
else
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 4: sweep Secrets & ConfigMaps ==========
_blue "==> [4/6] Sweep leftover Secrets / ConfigMaps"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete secret    -l '$LABEL' --ignore-not-found"
  run "kubectl -n '$NAMESPACE' delete configmap -l '$LABEL' --ignore-not-found"
else
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 5: PVCs (drops all databases with the Postgres volume) ==========
_blue "==> [5/6] Delete PVCs"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  BOUND_PVS=$(kubectl -n "$NAMESPACE" get pvc -l "$LABEL" \
    -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
  run "kubectl -n '$NAMESPACE' delete pvc -l '$LABEL' --ignore-not-found"
else
  BOUND_PVS=""
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 6: PVs ==========
_blue "==> [6/6] Delete PVs"
if [[ "$KEEP_PVS" == true ]]; then
  _yellow "  (skipped — --keep-pvs)"
else
  pv_claimed=$(kubectl get pv -o json 2>/dev/null | \
    jq -r --arg ns "$NAMESPACE" \
      '.items[] | select(.spec.claimRef.namespace==$ns) | select(.status.phase=="Released" or .status.phase=="Failed") | .metadata.name' \
    2>/dev/null || true)
  pv_all=$(echo "$BOUND_PVS $pv_claimed" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  if [[ -z "${pv_all// }" ]]; then
    echo "  (no PVs to delete)"
  else
    for pv in $pv_all; do run "kubectl delete pv '$pv' --ignore-not-found"; done
  fi
fi

echo
_green "==> Base infrastructure uninstall complete."
[[ "$DRY_RUN" == true ]] && _yellow "    (dry-run — nothing was actually changed)"
