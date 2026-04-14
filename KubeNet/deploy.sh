#!/bin/bash
# ============================================================
# deploy.sh — Orquestador principal de KubeNet
#
# Ejecuta los scripts en orden. Si uno falla, el despliegue
# se detiene e indica exactamente en qué paso falló, para que
# puedas corregirlo y re-ejecutar solo ese script.
#
# FLUJO COMPLETO:
#   ./install.sh          → instala Docker, kubectl, Minikube, Helm
#   ./setup.sh            → configura contraseñas (.env)
#   minikube start ...    → arranca el clúster
#   ./deploy.sh           → despliega todo
#
# OPCIONES:
#   ./deploy.sh           → despliegue completo
#   ./deploy.sh --cleanup → elimina todo el despliegue
#   ./deploy.sh --from 4  → reanuda desde el script 04
#   ./deploy.sh --only 7  → ejecuta solo el script 07
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

case "$1" in
  --cleanup)
    bash "$SCRIPTS_DIR/10-cleanup.sh" "${@:2}"
    exit $?
    ;;
  --from)
    FROM_STEP="${2:-0}"
    ONLY_STEP=0
    ;;
  --only)
    ONLY_STEP="${2:-0}"
    FROM_STEP=0
    ;;
  --help|-h)
    echo ""
    echo -e "${BLUE}KubeNet deploy.sh — Uso:${NC}"
    echo ""
    echo "  ./deploy.sh               Despliegue completo"
    echo "  ./deploy.sh --cleanup     Eliminar todo el despliegue"
    echo "  ./deploy.sh --from N      Reanudar desde el paso N"
    echo "  ./deploy.sh --only N      Ejecutar solo el paso N"
    echo ""
    echo "  Pasos disponibles:"
    echo "    00 — Verificaciones previas"
    echo "    01 — Precargar imágenes en Minikube"
    echo "    02 — Instalar herramientas del clúster"
    echo "    03 — Core: namespaces, secrets, configmaps, PVCs"
    echo "    04 — Data: MariaDB HA + Redis HA"
    echo "    05 — Storage: MinIO + backups"
    echo "    06 — App: WordPress + TLS + Ingress + autoscaling"
    echo "    07 — Observabilidad: Prometheus + Loki + Jaeger + Grafana"
    echo "    08 — Velero (backup del clúster)"
    echo "    09 — Red: tunnel + /etc/hosts"
    echo ""
    exit 0
    ;;
  *)
    FROM_STEP=0
    ONLY_STEP=0
    ;;
esac

STEPS=(
  "00-check-prerequisites.sh"
  "01-load-images.sh"
  "02-install-tools.sh"
  "03-deploy-core.sh"
  "04-deploy-data.sh"
  "05-deploy-storage.sh"
  "06-deploy-app.sh"
  "07-deploy-observability.sh"
  "08-deploy-velero.sh"
  "09-setup-network.sh"
)

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   KubeNet — Despliegue WordPress HA en Kubernetes${NC}"
echo -e "${BLUE}============================================================${NC}"
[ "${FROM_STEP:-0}" -gt 0 ] && echo -e "${YELLOW}   Reanudando desde el paso ${FROM_STEP}${NC}"
[ "${ONLY_STEP:-0}" -gt 0 ] && echo -e "${YELLOW}   Ejecutando solo el paso ${ONLY_STEP}${NC}"
echo ""

START_TIME=$(date +%s)

for STEP_FILE in "${STEPS[@]}"; do
  STEP_NUM="${STEP_FILE:0:2}"
  STEP_NUM_INT=$((10#$STEP_NUM))

  if [ "${ONLY_STEP:-0}" -gt 0 ] && [ "$STEP_NUM_INT" -ne "$ONLY_STEP" ]; then
    continue
  fi
  if [ "${FROM_STEP:-0}" -gt 0 ] && [ "$STEP_NUM_INT" -lt "$FROM_STEP" ]; then
    echo -e "${YELLOW}[SKIP]${NC} Paso ${STEP_NUM} — saltado (--from ${FROM_STEP})"
    continue
  fi

  STEP_PATH="$SCRIPTS_DIR/$STEP_FILE"

  if [ ! -f "$STEP_PATH" ]; then
    echo -e "${RED}[ERROR]${NC} Script no encontrado: $STEP_PATH"
    exit 1
  fi

  chmod +x "$STEP_PATH"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  STEP_START=$(date +%s)

  if ! bash "$STEP_PATH"; then
    STEP_END=$(date +%s)
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ✗ FALLO en el paso ${STEP_NUM}: ${STEP_FILE}${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}  Para re-ejecutar solo este paso:${NC}"
    echo -e "    ${GREEN}bash $STEP_PATH${NC}"
    echo ""
    echo -e "${YELLOW}  Para reanudar el despliegue desde aquí:${NC}"
    echo -e "    ${GREEN}./deploy.sh --from ${STEP_NUM_INT}${NC}"
    echo ""
    exit 1
  fi

  STEP_END=$(date +%s)
  STEP_ELAPSED=$((STEP_END - STEP_START))
  echo -e "${GREEN}  ✓ Paso ${STEP_NUM} completado en ${STEP_ELAPSED}s${NC}"
done

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))

echo ""
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       ✅  Despliegue completado con éxito                ║${NC}"
echo -e "${GREEN}║       ⏱  Tiempo total: ${TOTAL_MIN}m ${TOTAL_SEC}s                           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🌐  URLs de acceso${NC}"
echo -e "    ${GREEN}WordPress${NC}   →  https://wp-k8s.local"
echo -e "    ${GREEN}Grafana${NC}     →  https://grafana.monitoring.local  (credenciales en .env)"
echo -e "    ${GREEN}Prometheus${NC}  →  https://prometheus.monitoring.local"
echo -e "    ${GREEN}MinIO${NC}       →  http://minio.storage.local"
echo -e "    ${GREEN}Jaeger${NC}      →  kubectl port-forward -n monitoring svc/jaeger-query 16686:16686"
echo ""
echo -e "${BLUE}💾  Backups${NC}"
echo -e "    MariaDB dump   → MinIO diario 2:00 AM"
echo -e "    Uploads WP     → MinIO diario 3:00 AM"
echo -e "    Velero cluster → Diario 1:00 AM  |  RPO: ~24h  |  RTO: ~15 min"
echo ""
echo -e "${BLUE}🔧  Comandos útiles${NC}"
echo -e "    kubectl get pods -A"
echo -e "    kubectl get scaledobject -n wordpress"
echo -e "    velero backup get"
echo -e "    kubectl get certificates -A"
echo ""
echo -e "    ./deploy.sh --cleanup          # eliminar todo"
echo -e "    ./deploy.sh --from N           # reanudar desde paso N"
echo -e "    ./deploy.sh --only N           # ejecutar solo paso N"
echo ""
