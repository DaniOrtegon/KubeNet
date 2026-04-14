#!/bin/bash
# ============================================================
# 05-deploy-storage.sh — MinIO + Backup CronJobs
#
# Despliega:
#   1. MinIO (almacenamiento S3 compatible)
#   2. Job de inicialización de buckets (wordpress-uploads, wordpress-backups)
#   3. CronJobs de backup (MariaDB dump + uploads → MinIO)
#
# BUG CORREGIDO: el script original borraba el job minio-setup
# justo después de aplicar minio.yaml (que ya lo incluye), y luego
# intentaba esperar a que completase — el kubectl wait fallaba
# siempre porque el job acababa de ser eliminado.
#
# Solución: comprobar si el job ya completó (re-deploy idempotente);
# si no existe o está en fallo, borrarlo y reaplicar minio.yaml,
# luego esperar a que complete ANTES de continuar.
#
# USO:
#   ./scripts/05-deploy-storage.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K8S_DIR="$SCRIPT_DIR/k8s"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [05] Storage: MinIO + Backups${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. MinIO Deployment + Service + Secret
# ------------------------------------------------------------
apply_file "$K8S_DIR/storage/minio.yaml" "MinIO (almacenamiento S3)"
wait_for_deployment "storage" "minio" 180

# ------------------------------------------------------------
# 2. Job de inicialización de buckets
#
# minio.yaml incluye el Job minio-setup. En re-deploys puede
# estar en estado Completed (OK), Running, Failed, o puede que
# el ttlSecondsAfterFinished ya lo haya eliminado.
#
# Flujo correcto:
#   a) Job existe y completó → buckets OK, no hacer nada
#   b) Job no existe o falló → borrar + reaplicar + esperar
# ------------------------------------------------------------
log_info "Verificando job de inicialización de buckets MinIO..."

JOB_STATUS=$(kubectl get job minio-setup -n storage \
  -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")

if [ "$JOB_STATUS" = "True" ]; then
  log_success "Job minio-setup ya completó — buckets listos"
else
  log_info "Recreando job minio-setup..."
  # Borrar si existe en cualquier estado (fallido, pendiente, etc.)
  kubectl delete job minio-setup -n storage --ignore-not-found=true 2>/dev/null || true
  sleep 2
  # Reaplicar minio.yaml completo para que k8s cree el Job de nuevo
  apply_file "$K8S_DIR/storage/minio.yaml" "MinIO (recreando job de buckets)"

  log_info "Esperando a que el job minio-setup complete (hasta 2 min)..."
  kubectl wait --for=condition=complete job/minio-setup \
    -n storage --timeout=120s 2>/dev/null \
    && log_success "Buckets MinIO creados correctamente" \
    || log_warn "Job minio-setup no completó en 120s — verifica: kubectl logs -n storage job/minio-setup"
fi

# ------------------------------------------------------------
# 3. Backup CronJobs (MariaDB dump + uploads → MinIO)
# ------------------------------------------------------------
apply_file "$K8S_DIR/storage/backup.yaml" "CronJobs de backup (MariaDB + uploads → MinIO)"

echo ""
log_success "[05] Storage desplegado correctamente"
echo ""
