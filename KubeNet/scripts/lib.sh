#!/bin/bash
# ============================================================
# lib.sh — Funciones compartidas para todos los scripts de KubeNet
# Se carga con: source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib.sh"
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Aplicar un archivo YAML con kubectl apply
apply_file() {
  local file=$1
  local description=$2
  log_info "Aplicando: $description..."
  if kubectl apply -f "$file"; then
    log_success "$description aplicado"
  else
    log_warn "Error al aplicar $file — verificar manualmente"
  fi
}

# Esperar a que un Deployment esté Ready
# NO termina el script en timeout — avisa y continúa
wait_for_deployment() {
  local namespace=$1
  local deployment=$2
  local timeout=${3:-300}
  local elapsed=0
  local interval=15

  log_info "Esperando Deployment '$deployment' en '$namespace' (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    local ready desired
    ready=$(kubectl get deployment "$deployment" -n "$namespace" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(kubectl get deployment "$deployment" -n "$namespace" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    ready=${ready:-0}
    desired=${desired:-1}

    if [ "$ready" -ge "$desired" ] 2>/dev/null && [ "$desired" -gt 0 ] 2>/dev/null; then
      log_success "$deployment listo ($ready/$desired réplicas)"
      return 0
    fi

    if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
      log_info "[$elapsed/${timeout}s] $deployment: $ready/$desired ready. Pods:"
      kubectl get pods -n "$namespace" -l "app=$deployment" --no-headers 2>/dev/null | \
        awk '{printf "  %s  %s  %s\n", $1, $3, $4}' || true
    else
      echo -n "."
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo ""
  log_warn "TIMEOUT: $deployment no alcanzó Ready en ${timeout}s"
  log_warn "Estado actual de pods en $namespace:"
  kubectl get pods -n "$namespace" 2>/dev/null || true
  log_warn "Continuando despliegue — puede arrancar en segundo plano"
}

# Esperar a que un StatefulSet esté Ready
# NO termina el script en timeout — avisa y continúa
wait_for_statefulset() {
  local namespace=$1
  local sts=$2
  local timeout=${3:-600}
  local replicas=${4:-1}
  local elapsed=0
  local interval=15

  log_info "Esperando StatefulSet '$sts' en '$namespace' (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    local ready desired
    ready=$(kubectl get statefulset "$sts" -n "$namespace" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(kubectl get statefulset "$sts" -n "$namespace" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "$replicas")
    ready=${ready:-0}
    desired=${desired:-$replicas}

    if [ "$ready" -ge "$desired" ] 2>/dev/null && [ "$desired" -gt 0 ] 2>/dev/null; then
      log_success "StatefulSet $sts listo ($ready/$desired réplicas)"
      return 0
    fi

    if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
      log_info "[$elapsed/${timeout}s] $sts: $ready/$desired ready. Pods:"
      kubectl get pods -n "$namespace" -l "app=$sts" --no-headers 2>/dev/null | \
        awk '{printf "  %s  %s  %s\n", $1, $3, $4}' || true
      kubectl get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | \
        grep -i "error\|warning\|failed\|backoff" | tail -3 | \
        awk '{printf "  EVENT: %s\n", $0}' || true
    else
      echo -n "."
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo ""
  log_warn "TIMEOUT: $sts no alcanzó Ready en ${timeout}s"
  log_warn "Estado actual de pods en $namespace:"
  kubectl get pods -n "$namespace" 2>/dev/null || true
  log_warn "Continuando despliegue"
}

# Eliminar namespace de forma segura, forzando finalizers si se queda en Terminating
delete_namespace_safe() {
  local ns=$1
  local timeout=${2:-30}
  local elapsed=0

  kubectl get namespace "$ns" &>/dev/null || return 0
  kubectl delete namespace "$ns" --ignore-not-found=true 2>/dev/null || true

  while [ $elapsed -lt $timeout ]; do
    kubectl get namespace "$ns" &>/dev/null || return 0
    echo -n "."
    sleep 2
    elapsed=$((elapsed + 2))
  done

  local phase
  phase=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$phase" = "Terminating" ]; then
    log_warn "Namespace '$ns' atascado — forzando finalizers..."
    kubectl get namespace "$ns" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
  fi
  return 0
}
