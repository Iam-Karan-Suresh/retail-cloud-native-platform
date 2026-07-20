#!/usr/bin/env bash
# =============================================================================
# LOCAL CLUSTER TEARDOWN — Retail Cloud Native Platform
# =============================================================================
# Destroys the Kind cluster and all associated resources.
#
# Usage:
#   ./local/teardown.sh              # Delete cluster
#   ./local/teardown.sh --apps-only  # Uninstall Helm releases only (keep cluster)
# =============================================================================
set -euo pipefail

CLUSTER_NAME="retail-store-local"
NAMESPACE="retail-store"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_header() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  $1${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

log_ok() {
  echo -e "  ${GREEN}✅ $1${NC}"
}

# ---------------------------------------------------------------------------
# PARSE ARGUMENTS
# ---------------------------------------------------------------------------
APPS_ONLY=false

for arg in "$@"; do
  case $arg in
    --apps-only) APPS_ONLY=true ;;
    --help|-h)
      echo "Usage: ./local/teardown.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --apps-only   Uninstall Helm releases only, keep cluster running"
      echo "  --help, -h    Show this help message"
      exit 0
      ;;
  esac
done

if [ "$APPS_ONLY" = true ]; then
  log_header "UNINSTALLING APPLICATIONS ONLY"

  for service in cart catalog checkout orders ui; do
    echo "  Uninstalling retail-store-${service}..."
    helm uninstall "retail-store-${service}" -n "${NAMESPACE}" 2>/dev/null || true
  done

  # Optionally uninstall infra
  echo ""
  echo -e "${YELLOW}  Infrastructure (Traefik, KEDA) is still running.${NC}"
  echo -e "${YELLOW}  To remove: helm uninstall traefik -n traefik-system${NC}"
  echo -e "${YELLOW}             helm uninstall keda -n keda${NC}"
  echo ""

  log_ok "Applications uninstalled"
else
  log_header "DESTROYING KIND CLUSTER"

  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    log_ok "Cluster '${CLUSTER_NAME}' deleted"
  else
    echo -e "  ${YELLOW}Cluster '${CLUSTER_NAME}' not found — nothing to delete${NC}"
  fi

  # Clean up docker volumes/networks left by Kind
  docker volume prune -f 2>/dev/null || true

  log_ok "Teardown complete"
fi
