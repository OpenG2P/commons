#!/usr/bin/env bash
#
# uninstall.sh  (openg2p-commons-services)
# ----------------------------------------
# Cleanly uninstall the commons application-services Helm release and every
# resource it created that `helm uninstall` leaves behind:
#
#   1. helm uninstall <release>                (helm-owned workloads/secrets/cm)
#   2. Delete leftover Jobs + their Pods       (post/pre-install hook Jobs use
#                                               hook-delete-policy: before-hook-creation,
#                                               so helm uninstall does NOT remove them)
#   3. Delete orphaned hook ServiceAccounts    (hook SAs have no
#                                               meta.helm.sh/release-name ownership and
#                                               BLOCK the next install with
#                                               "cannot be imported into the current release")
#   4. Sweep leftover Secrets / ConfigMaps     (incl. resource-policy: keep per-DB /
#                                               client secrets that survive uninstall)
#   5. Drop services-owned Postgres DBs+roles  (awe, iam, audit_manager,
#                                               partner_management, master_data — they live
#                                               in the shared commons-postgresql and are NOT
#                                               owned by this release, so they survive;
#                                               leaving them causes reinstall auth failures
#                                               once the *-db-user secret is regenerated)
#   6. Delete PVCs by label                    (keymanager .p12 keystore, superset, …)
#   7. Delete PVs still bound to those PVCs
#
# NOT removed (by design): base infrastructure — PostgreSQL server, Kafka, MinIO,
# Redis, SoftHSM, Keycloak — and the databases OWNED by commons-base
# (superset, odkdb, mosip_esignet, mosip_mockidentitysystem, mosip_keymgr, keycloak).
# Those belong to commons-base; run uninstall-base.sh to remove them (deleting the
# PostgreSQL PVC there drops every database at once).
#
# Also NOT removed: Keycloak *clients* created by keycloak-init (awe-admin-portal,
# awe-admin-resolver, superset, odk, staff-portal, pm-*). They are created via the
# Keycloak admin API, not as K8s resources, so no `kubectl`/`helm` step removes them.
# They are idempotent on reinstall; delete manually in Keycloak if you need them gone.
#
# Requires: kubectl (cluster admin), helm, bash 4+, jq.
#
# USAGE:
#   ./uninstall.sh --namespace <ns> [options]
#     --namespace, -n <ns>        (required) Kubernetes namespace
#     --release <name>            Helm release name          (default: commons-services)
#     --postgres-release <name>   commons-postgresql release (default: commons-postgresql)
#     --postgres-namespace <ns>   namespace of Postgres      (default: same as --namespace)
#     --keep-dbs                  do NOT drop Postgres databases/roles
#     --reset-keymanager          also clear esignet / mock-identity key_alias+key_store
#                                 (needed if softhsm was reset — see note below)
#     --keep-pvs                  delete PVCs but not the PVs behind them
#     --dry-run                   print actions, change nothing
#     --yes, -y                   skip the interactive confirmation
#
# EXAMPLES:
#   ./uninstall.sh -n trial --dry-run
#   ./uninstall.sh -n trial
#   ./uninstall.sh -n trial --yes

set -euo pipefail

# ---------- defaults ----------
RELEASE="commons-services"
NAMESPACE=""
POSTGRES_RELEASE="commons-postgresql"
POSTGRES_NAMESPACE=""
KEEP_DBS=false
KEEP_PVS=false
RESET_KEYMANAGER=false
DRY_RUN=false
ASSUME_YES=false

# ---------- services-owned Postgres databases/roles ----------
# These are created by commons-services subcharts' postgres-init inside the shared
# commons-postgresql instance. They are NOT owned by this Helm release and survive
# `helm uninstall`. name=DB, value=role. Base-owned DBs (esignet, mock-identity,
# keymgr, superset, odk, keycloak) are intentionally excluded — see header.
# NOTE: keep this in sync when a services subchart that creates its own DB is
# added. registry/registry_idgenerator belong to the registry (NSR) release —
# NOT commons-services — and must never appear here.
# ---------- keymanager state owned by esignet / mock-identity ----------
# These two run PKCS11: their key MATERIAL lives in softhsm (base-owned) while
# their key_alias rows live in these base-owned DBs. The two are excluded from
# SERVICE_DBS on purpose, but that means the aliases survive a services
# uninstall. If softhsm is ever reset/reinstalled while they survive, the
# aliases reference HSM keys that no longer exist and the apps fail at
# keymanager/ROOT KEY init. --reset-keymanager truncates just the key tables so
# the next start regenerates them against whatever softhsm currently holds.
# Application data (client_detail, consent_*, mock_identity, kyc_auth) is kept.
# db:schema
KEYMANAGER_DBS=(
  "mosip_esignet:esignet"
  "mosip_mockidentitysystem:mockidentitysystem"
)

SERVICE_DBS=(
  "awe:awe_user"
  "iam:iam_user"
  "audit_manager:audit_manager_user"
  "partner_management:partner_management_user"
  "consent_manager:consent_manager_user"
  "master_data:master_data_user"
  # belt-and-suspenders: some render paths name the master-data DB with the
  # release prefix; DROP ... IF EXISTS makes this a no-op when absent.
  "commons_services_master_data:commons_services_master_data_user"
)

# ---------- cli ----------
usage() { sed -n '2,45p' "$0"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)            RELEASE="$2";            shift 2 ;;
    --namespace|-n)       NAMESPACE="$2";          shift 2 ;;
    --postgres-release)   POSTGRES_RELEASE="$2";   shift 2 ;;
    --postgres-namespace) POSTGRES_NAMESPACE="$2"; shift 2 ;;
    --keep-dbs)           KEEP_DBS=true;           shift ;;
    --reset-keymanager)   RESET_KEYMANAGER=true;   shift ;;
    --keep-pvs)           KEEP_PVS=true;           shift ;;
    --dry-run)            DRY_RUN=true;            shift ;;
    --yes|-y)             ASSUME_YES=true;         shift ;;
    -h|--help)            usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAMESPACE" ]] && { echo "ERROR: --namespace is required"; usage; }
[[ -z "$POSTGRES_NAMESPACE" ]] && POSTGRES_NAMESPACE="$NAMESPACE"

LABEL="app.kubernetes.io/instance=$RELEASE"

# ---------- helpers ----------
_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
_green() { printf "\033[32m%s\033[0m\n" "$*"; }
_yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

run() {
  # Print + execute (or just print if --dry-run). Never aborts on non-zero —
  # cleanup must be idempotent; already-deleted resources are fine.
  echo "  \$ $*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@" || _yellow "  (command returned non-zero — continuing)"
  fi
}

kexec_psql() {
  local sql="$1"
  echo "  \$ psql -U postgres -c \"$sql\""
  if [[ "$DRY_RUN" == false ]]; then
    kubectl exec -n "$POSTGRES_NAMESPACE" "$PG_POD" -c postgresql -- \
      bash -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U postgres -v ON_ERROR_STOP=0 -c \"$sql\"" \
      || _yellow "  (psql returned non-zero — continuing)"
  fi
}

kexec_psql_db() {
  # Like kexec_psql but connects to a specific database (-d).
  local db="$1"; local sql="$2"
  echo "  \$ psql -U postgres -d $db -c \"$sql\""
  if [[ "$DRY_RUN" == false ]]; then
    kubectl exec -n "$POSTGRES_NAMESPACE" "$PG_POD" -c postgresql -- \
      bash -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U postgres -d \"$db\" -v ON_ERROR_STOP=0 -c \"$sql\"" \
      || _yellow "  (psql returned non-zero — continuing)"
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

# Locate commons-postgresql pod (for DB drop).
PG_POD=""
if [[ "$KEEP_DBS" == false ]] && kubectl get ns "$POSTGRES_NAMESPACE" >/dev/null 2>&1; then
  PG_POD=$(kubectl get pod -n "$POSTGRES_NAMESPACE" \
    -l "app.kubernetes.io/instance=$POSTGRES_RELEASE,app.kubernetes.io/name=postgresql" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -z "$PG_POD" ]] && kubectl get pod -n "$POSTGRES_NAMESPACE" "${POSTGRES_RELEASE}-0" >/dev/null 2>&1 \
    && PG_POD="${POSTGRES_RELEASE}-0"
fi
if [[ "$KEEP_DBS" == true ]]; then
  _yellow "  DB drop disabled (--keep-dbs)"; PG_POD_FOUND=false
elif [[ -z "$PG_POD" ]]; then
  PG_POD_FOUND=false; _yellow "  commons-postgresql pod not found — DB drop will be skipped"
else
  PG_POD_FOUND=true;  _green "  Found Postgres pod: $PG_POD ($POSTGRES_NAMESPACE)"
fi

if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  HELM_RELEASE_EXISTS=true;  _green "  Helm release '$RELEASE' found"
else
  HELM_RELEASE_EXISTS=false; _yellow "  Helm release '$RELEASE' not found — skipping helm uninstall"
fi

# ---------- blast radius ----------
_blue "==> Resources to be deleted"
echo
echo "Helm release:    $RELEASE (ns: $NAMESPACE)"
if [[ "$KEEP_DBS" == true ]]; then
  echo "Postgres DBs:    (skipped — --keep-dbs)"
else
  echo "Postgres DBs:    ${SERVICE_DBS[*]%%:*}  (in $POSTGRES_RELEASE)"
fi
echo
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  for kind in job secret configmap pvc serviceaccount; do
    echo "${kind}s (label $LABEL):"
    kubectl -n "$NAMESPACE" get "$kind" -l "$LABEL" --no-headers 2>/dev/null \
      | awk '{print "  - " $1}' || echo "  (none)"
  done
fi
echo

# ---------- confirmation ----------
[[ "$DRY_RUN" == true ]] && _yellow "DRY-RUN: no changes will be made."
if [[ "$ASSUME_YES" == false && "$DRY_RUN" == false ]]; then
  _red "This is destructive. Type the release name ('$RELEASE') to confirm:"
  read -r CONFIRM
  [[ "$CONFIRM" != "$RELEASE" ]] && { _red "Confirmation did not match. Aborting."; exit 1; }
fi

# ========== STEP 1: helm uninstall ==========
_blue "==> [1/7] Helm uninstall"
if [[ "$HELM_RELEASE_EXISTS" == true ]]; then
  run "helm uninstall '$RELEASE' -n '$NAMESPACE' --wait --timeout 10m || true"
else
  echo "  (skipped — release not present)"
fi

# ========== STEP 2: leftover Jobs + Pods ==========
_blue "==> [2/7] Delete leftover Jobs and their Pods"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete job -l '$LABEL' --ignore-not-found --wait=true --timeout=2m"
  run "kubectl -n '$NAMESPACE' delete pod -l '$LABEL' --ignore-not-found --field-selector=status.phase!=Running"
else
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 3: orphaned hook ServiceAccounts + RBAC ==========
# Hook SAs (postgres-init / keycloak-init / etc.) carry the instance label but no
# helm ownership annotation, so they survive uninstall and BLOCK the next install.
_blue "==> [3/7] Delete orphaned ServiceAccounts / RBAC"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete serviceaccount -l '$LABEL' --ignore-not-found"
  run "kubectl -n '$NAMESPACE' delete role,rolebinding -l '$LABEL' --ignore-not-found"
  # master-data's postgres-init SA is not release-prefixed and can predate labels.
  run "kubectl -n '$NAMESPACE' delete serviceaccount master-data-postgres-init --ignore-not-found"
else
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 4: sweep Secrets & ConfigMaps ==========
# Catches resource-policy:keep per-DB / client secrets (awe-db-user, iam,
# audit-manager, master-data, partner-management-db, …) that survive uninstall.
_blue "==> [4/7] Sweep leftover Secrets / ConfigMaps"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  run "kubectl -n '$NAMESPACE' delete secret    -l '$LABEL' --ignore-not-found"
  run "kubectl -n '$NAMESPACE' delete configmap -l '$LABEL' --ignore-not-found"
else
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 5: drop services-owned Postgres DBs & roles ==========
# Dropping the role together with deleting its *-db-user secret (step 4) is what
# keeps a reinstall clean: otherwise the regenerated secret would not match the
# surviving role's password and the pod would hang on DB auth.
_blue "==> [5/7] Drop services-owned Postgres databases and roles"
if [[ "$PG_POD_FOUND" == true ]]; then
  for entry in "${SERVICE_DBS[@]}"; do
    db="${entry%%:*}"; role="${entry##*:}"
    echo "  - Database: $db  (role: $role)"
    kexec_psql "REVOKE CONNECT ON DATABASE \\\"$db\\\" FROM PUBLIC;"
    kexec_psql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();"
    kexec_psql "DROP DATABASE IF EXISTS \\\"$db\\\";"
    kexec_psql "REASSIGN OWNED BY \\\"$role\\\" TO postgres;"
    kexec_psql "DROP OWNED BY \\\"$role\\\";"
    kexec_psql "DROP ROLE IF EXISTS \\\"$role\\\";"
  done
else
  echo "  (skipped — Postgres pod not reachable or --keep-dbs)"
fi

# ========== STEP 5b: reset esignet / mock-identity keymanager state ==========
# Opt-in. See KEYMANAGER_DBS above for why this is not automatic: these DBs are
# base-owned, so their key_alias rows outlive a services uninstall and only go
# stale if softhsm was reset independently.
_blue "==> [5b/7] Reset esignet / mock-identity keymanager keys"
if [[ "$RESET_KEYMANAGER" != true ]]; then
  echo "  (skipped — pass --reset-keymanager if softhsm was reset/reinstalled)"
elif [[ "$PG_POD_FOUND" != true ]]; then
  echo "  (skipped — Postgres pod not reachable)"
else
  for entry in "${KEYMANAGER_DBS[@]}"; do
    db="${entry%%:*}"; schema="${entry##*:}"
    echo "  - ${db} (schema ${schema}): clearing key_alias + key_store"
    kexec_psql_db "$db" "TRUNCATE TABLE \\\"${schema}\\\".key_alias, \\\"${schema}\\\".key_store;"
  done
fi

# ========== STEP 6: PVCs ==========
_blue "==> [6/7] Delete PVCs"
if [[ "$NAMESPACE_EXISTS" == true ]]; then
  # capture bound PV names before deleting the PVCs (for step 7)
  BOUND_PVS=$(kubectl -n "$NAMESPACE" get pvc -l "$LABEL" \
    -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
  run "kubectl -n '$NAMESPACE' delete pvc -l '$LABEL' --ignore-not-found"
else
  BOUND_PVS=""
  echo "  (skipped — namespace not present)"
fi

# ========== STEP 7: PVs ==========
_blue "==> [7/7] Delete PVs"
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
_green "==> Done."
[[ "$DRY_RUN" == true ]] && _yellow "    (dry-run — nothing was actually changed)"
echo "    Base infra (PostgreSQL/Kafka/MinIO/Redis/SoftHSM/Keycloak) untouched —"
echo "    run uninstall-base.sh from openg2p-commons-base to remove it."
