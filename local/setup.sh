#!/usr/bin/env bash
# =============================================================================
# LOCAL CLUSTER SETUP — Retail Cloud Native Platform
# =============================================================================
# Creates a Kind cluster and deploys all infrastructure + microservices
# for local development. No AWS dependencies.
#
# Usage:
#   ./local/setup.sh                    # In-memory backends (default)
#   ./local/setup.sh --stateful         # With MySQL, PostgreSQL, Redis, RabbitMQ
#   ./local/setup.sh --skip-infra       # Skip infra, deploy apps only
#   ./local/setup.sh --skip-apps        # Setup infra only, no apps
#
# Prerequisites: docker, kind, kubectl, helm
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
CLUSTER_NAME="retail-store-local"
NAMESPACE="retail-store"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_DIR="${SCRIPT_DIR}/values"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# PARSE ARGUMENTS
# ---------------------------------------------------------------------------
STATEFUL=false
SKIP_INFRA=false
SKIP_APPS=false

for arg in "$@"; do
  case $arg in
    --stateful)   STATEFUL=true ;;
    --skip-infra) SKIP_INFRA=true ;;
    --skip-apps)  SKIP_APPS=true ;;
    --help|-h)
      echo "Usage: ./local/setup.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --stateful     Deploy with real databases (MySQL, PostgreSQL, Redis, RabbitMQ)"
      echo "  --skip-infra   Skip infrastructure setup (cluster, Traefik, KEDA)"
      echo "  --skip-apps    Deploy infrastructure only, skip microservices"
      echo "  --help, -h     Show this help message"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown argument: $arg${NC}"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------------------------
log_header() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  $1${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

log_step() {
  echo -e "${BLUE}━━━ $1 ━━━${NC}"
}

log_ok() {
  echo -e "  ${GREEN}✅ $1${NC}"
}

log_warn() {
  echo -e "  ${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "  ${RED}❌ $1${NC}"
}

check_command() {
  if ! command -v "$1" &> /dev/null; then
    log_error "$1 is not installed. Please install it first."
    echo "  See: $2"
    exit 1
  fi
  log_ok "$1 found: $(command -v "$1")"
}

# ---------------------------------------------------------------------------
# PREFLIGHT CHECKS
# ---------------------------------------------------------------------------
log_header "PREFLIGHT CHECKS"

check_command "docker"  "https://docs.docker.com/get-docker/"
check_command "kind"    "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
check_command "kubectl" "https://kubernetes.io/docs/tasks/tools/"
check_command "helm"    "https://helm.sh/docs/intro/install/"

# Check Docker is running
if ! docker info &> /dev/null; then
  log_error "Docker daemon is not running. Please start Docker first."
  exit 1
fi
log_ok "Docker daemon is running"

echo ""

# =============================================================================
# PHASE 1: CREATE KIND CLUSTER
# =============================================================================
if [ "$SKIP_INFRA" = false ]; then

  log_header "PHASE 1: CREATE KIND CLUSTER"

  # Check if cluster already exists
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_warn "Cluster '${CLUSTER_NAME}' already exists"
    echo -e "  ${YELLOW}To recreate: kind delete cluster --name ${CLUSTER_NAME}${NC}"
    echo ""
  else
    log_step "Creating Kind cluster '${CLUSTER_NAME}'"
    kind create cluster --config "${SCRIPT_DIR}/kind-cluster.yaml" --wait 120s
    log_ok "Kind cluster created"
  fi

  # Set kubectl context
  kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || true
  log_ok "kubectl context set to kind-${CLUSTER_NAME}"

  # Wait for nodes to be ready
  log_step "Waiting for nodes to be ready"
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
  log_ok "All nodes ready"

  echo ""
  kubectl get nodes -o wide
  echo ""

  # ===========================================================================
  # PHASE 2: INSTALL GATEWAY API CRDs
  # ===========================================================================
  log_header "PHASE 2: INSTALL GATEWAY API CRDs"

  log_step "Installing Gateway API CRDs (required before Traefik)"
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml 2>/dev/null || \
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
  log_ok "Gateway API CRDs installed"

  # ===========================================================================
  # PHASE 3: INSTALL TRAEFIK (replaces Terraform helm_release)
  # ===========================================================================
  log_header "PHASE 3: INSTALL TRAEFIK"

  log_step "Adding Traefik Helm repository"
  helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
  helm repo update

  log_step "Installing Traefik v40.0.0"
  helm upgrade --install traefik traefik/traefik \
    --version 40.0.0 \
    --namespace traefik-system \
    --create-namespace \
    --set providers.kubernetesGateway.enabled=true \
    --set providers.kubernetesIngress.enabled=false \
    --set service.type=NodePort \
    --set "service.nodePorts.web=30080" \
    --set "service.nodePorts.websecure=30443" \
    --set deployment.replicas=1 \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=200m \
    --set resources.limits.memory=128Mi \
    --wait \
    --timeout 5m

  log_ok "Traefik installed (accessible at http://localhost:80)"

  # ===========================================================================
  # PHASE 4: INSTALL KEDA (replaces Terraform helm_release)
  # ===========================================================================
  log_header "PHASE 4: INSTALL KEDA"

  log_step "Adding KEDA Helm repository"
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update

  log_step "Installing KEDA v2.19.0"
  helm upgrade --install keda kedacore/keda \
    --version 2.19.0 \
    --namespace keda \
    --create-namespace \
    --set resources.operator.requests.cpu=50m \
    --set resources.operator.requests.memory=64Mi \
    --set resources.operator.limits.cpu=100m \
    --set resources.operator.limits.memory=128Mi \
    --wait \
    --timeout 5m

  log_ok "KEDA installed"

  # ===========================================================================
  # PHASE 5: INSTALL OBSERVABILITY STACK
  # ===========================================================================
  log_header "PHASE 5: INSTALL OBSERVABILITY STACK"

  log_step "Deploying observability stack (Prometheus, Grafana, Loki, Tempo, OTel)"

  # Check if the configs directory exists for kustomize
  if [ -d "${PROJECT_ROOT}/k8s/observability/configs" ]; then
    # Create the grafana credentials env file if it doesn't exist
    GRAFANA_CREDS="${PROJECT_ROOT}/k8s/observability/configs/grafana-admin-credentials.env"
    if [ ! -f "${GRAFANA_CREDS}" ]; then
      log_warn "Creating default Grafana admin credentials"
      mkdir -p "$(dirname "${GRAFANA_CREDS}")"
      echo "GF_SECURITY_ADMIN_USER=admin" > "${GRAFANA_CREDS}"
      echo "GF_SECURITY_ADMIN_PASSWORD=admin" >> "${GRAFANA_CREDS}"
    fi
    kubectl apply -k "${PROJECT_ROOT}/k8s/observability" 2>/dev/null || \
      log_warn "Observability stack had warnings (may need configs — non-blocking)"
  else
    log_warn "Observability configs not found — skipping (deploy manually later)"
  fi

fi # end SKIP_INFRA

# =============================================================================
# PHASE 6: DEPLOY MICROSERVICES
# =============================================================================
if [ "$SKIP_APPS" = false ]; then

  log_header "PHASE 6: DEPLOY MICROSERVICES"

  # Create namespace
  log_step "Creating namespace '${NAMESPACE}'"
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  log_ok "Namespace '${NAMESPACE}' ready"

  # Build Helm values arguments
  STATEFUL_FLAG=""
  if [ "$STATEFUL" = true ]; then
    log_warn "Stateful mode: deploying with real databases"
    STATEFUL_FLAG="-f ${SCRIPT_DIR}/values-local-stateful.yaml"
  fi

  # Deploy each service
  SERVICES=("catalog" "cart" "orders" "checkout" "ui")

  for service in "${SERVICES[@]}"; do
    CHART_PATH="${PROJECT_ROOT}/src/${service}/chart"
    LOCAL_VALUES="${VALUES_DIR}/${service}-local.yaml"

    if [ ! -d "${CHART_PATH}" ]; then
      log_warn "Chart not found: ${CHART_PATH} — skipping"
      continue
    fi

    log_step "Deploying ${service}"

    VALUES_ARGS=""
    if [ -f "${LOCAL_VALUES}" ]; then
      VALUES_ARGS="-f ${LOCAL_VALUES}"
    fi

    helm upgrade --install "retail-store-${service}" \
      "${CHART_PATH}" \
      --namespace "${NAMESPACE}" \
      ${VALUES_ARGS} \
      ${STATEFUL_FLAG} \
      --timeout 5m \
      --wait 2>&1 | tail -5 || log_warn "${service} deploy had warnings"

    log_ok "${service} deployed"
  done

  echo ""

  # ===========================================================================
  # PHASE 7: VERIFY DEPLOYMENT
  # ===========================================================================
  log_header "VERIFICATION"

  log_step "Pod Status"
  kubectl get pods -n "${NAMESPACE}" -o wide

  echo ""
  log_step "Services"
  kubectl get svc -n "${NAMESPACE}"

  echo ""
  log_step "Traefik"
  kubectl get pods -n traefik-system

  echo ""
  log_step "KEDA"
  kubectl get pods -n keda

fi # end SKIP_APPS

# =============================================================================
# SUMMARY
# =============================================================================
log_header "SETUP COMPLETE"

echo -e "${GREEN}  Retail Store UI:       http://localhost${NC}"
echo -e "${GREEN}  Traefik Dashboard:     kubectl port-forward -n traefik-system svc/traefik 9000:9000${NC}"
echo -e "${GREEN}  Grafana:               kubectl port-forward -n observability svc/grafana 3000:3000${NC}"
echo ""
echo -e "${CYAN}  Useful commands:${NC}"
echo "    kubectl get pods -n ${NAMESPACE}              # Check app pods"
echo "    kubectl get pods -A                            # Check all pods"
echo "    kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=retail-store-sample-ui-chart  # UI logs"
echo "    ./local/teardown.sh                            # Destroy cluster"
echo ""
if [ "$STATEFUL" = true ]; then
  echo -e "${YELLOW}  Stateful mode active — databases running in-cluster${NC}"
fi
echo ""
