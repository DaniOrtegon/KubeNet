#!/bin/bash
# ============================================================
# 04-deploy-data.sh — MariaDB HA + Redis HA
#
# Despliega en orden:
#   1. MariaDB HA (StatefulSet: primary + replica)
#   2. Job de configuración de replicación MariaDB
#   3. Redis HA (StatefulSet: master + 2 réplicas + Sentinel)
#
# MariaDB usa replicación primario-replica asíncrona.
# Redis usa Sentinel para alta disponibilidad y failover automático.
#
# USO:
#   ./scripts/04-deploy-data.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K8S_DIR="$SCRIPT_DIR/k8s"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [04] Data: MariaDB HA + Redis HA${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. MariaDB HA
#
# Si el StatefulSet ya existe con un spec diferente (p.ej. distinto
# número de réplicas), lo recreamos en modo --cascade=orphan para
# preservar los PVCs con los datos existentes.
# volumeClaimTemplates es inmutable en StatefulSets — no se puede
# actualizar con apply.
# ------------------------------------------------------------
log_info "Desplegando MariaDB HA (primary + replica)..."

if kubectl get statefulset mariadb -n databases &>/dev/null; then
  CURRENT_REPLICAS=$(kubectl get statefulset mariadb -n databases \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [ "$CURRENT_REPLICAS" != "2" ]; then
    log_warn "StatefulSet mariadb existente con spec diferente ($CURRENT_REPLICAS réplicas) — recreando..."
    kubectl delete statefulset mariadb -n databases --cascade=orphan 2>/dev/null || true
    sleep 5
  fi
fi

apply_file "$K8S_DIR/data/mariadb.yaml" "MariaDB HA (primary + replica)"
# Timeout largo: la primera ejecución incluye init de datos (5-10 min)
wait_for_statefulset "databases" "mariadb" 600 2

# ------------------------------------------------------------
# 2. Job de replicación MariaDB
#
# Se borra antes de aplicar para que siempre se ejecute de cero
# (los Jobs completados no se vuelven a ejecutar si no se borran).
# ------------------------------------------------------------
log_info "Configurando replicación MariaDB..."
kubectl delete job mariadb-replication-setup -n databases --ignore-not-found=true 2>/dev/null || true
apply_file "$K8S_DIR/data/mariadb-replication-job.yaml" "Job replicación MariaDB"

kubectl wait --for=condition=complete job/mariadb-replication-setup \
  -n databases --timeout=120s 2>/dev/null \
  && log_success "Replicación MariaDB configurada" \
  || log_warn "Job replicación no completó en 120s — verifica: kubectl logs -n databases job/mariadb-replication-setup"

# ------------------------------------------------------------
# 3. Redis HA (master + 2 réplicas + 3 Sentinels)
# ------------------------------------------------------------
apply_file "$K8S_DIR/data/redis.yaml" "Redis HA (master + 2 réplicas + Sentinel)"
wait_for_statefulset "databases" "redis" 300 3

echo ""
log_success "[04] Capa de datos desplegada correctamente"
echo ""
