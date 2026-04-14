#!/bin/bash
# ============================================================
# 07-deploy-observability.sh — Stack de observabilidad completo
#
# Despliega en orden:
#   1. Prometheus + Alertmanager (métricas)
#   2. Loki + Promtail (logs)
#   3. Jaeger + OTel Collector (trazas distribuidas)
#   4. Grafana (dashboards unificados)
#
# USO:
#   ./scripts/07-deploy-observability.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K8S_DIR="$SCRIPT_DIR/k8s"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [07] Observabilidad: Prometheus + Loki + Jaeger + Grafana${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. Prometheus + Alertmanager
# ------------------------------------------------------------
apply_file "$K8S_DIR/observability/prometheus.yaml" "Prometheus + Alertmanager"
wait_for_deployment "monitoring" "prometheus" 180
wait_for_deployment "monitoring" "alertmanager" 120

# ------------------------------------------------------------
# 2. Loki + Promtail
# ------------------------------------------------------------
apply_file "$K8S_DIR/observability/loki.yaml" "Loki + Promtail"
wait_for_deployment "monitoring" "loki" 180

# ------------------------------------------------------------
# 3. Jaeger + OTel Collector
# ------------------------------------------------------------
apply_file "$K8S_DIR/observability/tracing.yaml" "Jaeger + OTel Collector"
wait_for_deployment "monitoring" "jaeger" 120

# ------------------------------------------------------------
# 4. Grafana
# ------------------------------------------------------------
apply_file "$K8S_DIR/observability/grafana.yaml" "Grafana"
wait_for_deployment "monitoring" "grafana" 180

echo ""
log_success "[07] Stack de observabilidad desplegado correctamente"
echo ""
