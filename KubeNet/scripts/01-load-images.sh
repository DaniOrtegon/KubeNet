#!/bin/bash
# ============================================================
# 01-load-images.sh — Precargar imágenes en Minikube
#
# Descarga las imágenes en el Docker del host y las transfiere
# al daemon interno de Minikube. Esto evita ImagePullBackOff
# cuando imagePullPolicy: Never está configurado en los YAMLs.
#
# IMPORTANTE: los tags aquí deben coincidir EXACTAMENTE con
# los tags usados en los manifiestos YAML.
#
# Tiempo estimado primera ejecución: 10-20 minutos
#
# USO:
#   ./scripts/01-load-images.sh
# ============================================================

set -e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [01] Precargando imágenes en Minikube${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

log_info "Esto puede tardar 10-20 min en la primera ejecución..."
echo ""

IMAGES=(
  "mariadb:10.6"
  "redis:6.2-alpine"
  "wordpress:6.4"
  "busybox:1.36"
  "alpine:3.18"
  "prom/prometheus:v2.48.0"
  "prom/alertmanager:v0.26.0"
  "grafana/grafana:10.2.3"
  "grafana/loki:2.9.3"
  "grafana/promtail:2.9.3"
  "jaegertracing/all-in-one:1.52"
  "otel/opentelemetry-collector-contrib:0.91.0"
  "minio/minio:RELEASE.2024-01-16T16-07-38Z"
  "minio/mc:RELEASE.2024-01-16T16-07-38Z"
  "registry.k8s.io/ingress-nginx/controller:v1.14.1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.4"
  "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.10.0"
  "bitnami/sealed-secrets-controller:0.26.3"
  "ghcr.io/kedacore/keda:2.19.0"
  "ghcr.io/kedacore/keda-metrics-apiserver:2.19.0"
  "ghcr.io/kedacore/keda-admission-webhooks:2.19.0"
  "velero/velero:v1.12.4"
  "velero/velero-plugin-for-aws:v1.8.2"
  "quay.io/jetstack/cert-manager-controller:v1.14.4"
  "quay.io/jetstack/cert-manager-cainjector:v1.14.4"
  "quay.io/jetstack/cert-manager-webhook:v1.14.4"
  "quay.io/jetstack/cert-manager-startupapicheck:v1.14.4"
)

FAILED=()

for IMAGE in "${IMAGES[@]}"; do
  if ! docker image inspect "$IMAGE" &>/dev/null; then
    log_info "Descargando en host: $IMAGE"
    if ! docker pull "$IMAGE"; then
      log_warn "No se pudo descargar $IMAGE — continuando"
      FAILED+=("$IMAGE")
      continue
    fi
  else
    log_success "Ya existe en host: $IMAGE"
  fi

  if minikube image ls 2>/dev/null | grep -qF "$IMAGE"; then
    log_success "Ya existe en Minikube: $IMAGE"
  else
    log_info "Cargando en Minikube: $IMAGE"
    if minikube image load "$IMAGE"; then
      log_success "Cargada: $IMAGE"
    else
      log_warn "No se pudo cargar $IMAGE en Minikube"
      FAILED+=("$IMAGE")
    fi
  fi
done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
  log_warn "Las siguientes imágenes no se pudieron cargar:"
  for img in "${FAILED[@]}"; do
    echo "  - $img"
  done
  log_warn "El despliegue puede tener ImagePullBackOff en los pods que las usen."
else
  log_success "Todas las imágenes disponibles en Minikube"
fi
echo ""
