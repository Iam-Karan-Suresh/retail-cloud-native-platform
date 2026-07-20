#!/bin/bash
# =============================================================================
# DEPLOY SCRIPT — Retail Cloud Native Platform
# =============================================================================
# Deploys all microservices via Helm.
#
# Usage:
#   ./deploy.sh                       # Deploy with default values (AWS)
#   ./deploy.sh --local               # Deploy with local Kind values
#   ./deploy.sh --local --stateful    # Deploy with local + stateful backends
#   ./deploy.sh --namespace myns      # Deploy to custom namespace
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# DEFAULTS
# ---------------------------------------------------------------------------
NAMESPACE="retail-store"
LOCAL_MODE=false
STATEFUL=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# PARSE ARGUMENTS
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --local)     LOCAL_MODE=true; shift ;;
    --stateful)  STATEFUL=true; shift ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: ./deploy.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --local        Deploy with local Kind values (no AWS scheduling)"
      echo "  --stateful     Enable real databases (MySQL, PostgreSQL, Redis, RabbitMQ)"
      echo "  --namespace NS Deploy to specified namespace (default: retail-store)"
      echo "  --help, -h     Show this help message"
      exit 0
      ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# DEPLOY
# ---------------------------------------------------------------------------
echo "Applying Observability Stack..."
kubectl apply -k k8s/observability 2>/dev/null || echo "⚠️  Observability stack had warnings (non-blocking)"

echo "Creating namespace..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying Helm charts..."

for service in catalog cart orders checkout ui; do
  CHART_PATH="./src/${service}/chart"
  VALUES_ARGS=""

  # Apply local values overlay if --local flag is set
  if [ "$LOCAL_MODE" = true ]; then
    LOCAL_VALUES="${SCRIPT_DIR}/local/values/${service}-local.yaml"
    if [ -f "${LOCAL_VALUES}" ]; then
      VALUES_ARGS="-f ${LOCAL_VALUES}"
    fi
  fi

  # Apply stateful overlay if --stateful flag is set
  if [ "$STATEFUL" = true ]; then
    STATEFUL_VALUES="${SCRIPT_DIR}/local/values-local-stateful.yaml"
    if [ -f "${STATEFUL_VALUES}" ]; then
      VALUES_ARGS="${VALUES_ARGS} -f ${STATEFUL_VALUES}"
    fi
  fi

  echo "  Deploying ${service}..."
  helm upgrade --install "retail-store-${service}" \
    "${CHART_PATH}" \
    -n "${NAMESPACE}" \
    ${VALUES_ARGS} \
    --timeout 5m \
    --wait 2>&1 | tail -5 || echo "  ⚠️  ${service} deploy had warnings"
done

echo ""
echo "Deployments initiated."
echo ""
kubectl get pods -n "${NAMESPACE}" -o wide
