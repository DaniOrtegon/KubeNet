#!/bin/bash
# ============================================================
# 00-check-prerequisites.sh — Verificaciones previas al despliegue
#
# Comprueba que todas las herramientas necesarias están disponibles
# y que Minikube está corriendo con la StorageClass requerida.
#
# USO:
#   ./scripts/00-check-prerequisites.sh
# ============================================================

set -e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [00] Verificaciones previas${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

log_info "Verificando requisitos previos..."

command -v kubectl &>/dev/null  || log_error "kubectl no encontrado. Ejecuta: ./install.sh"
log_success "kubectl encontrado: $(kubectl version --client --short 2>/dev/null | head -1)"

command -v docker &>/dev/null   || log_error "docker no encontrado. Ejecuta: ./install.sh"
log_success "docker encontrado: $(docker --version)"

command -v helm &>/dev/null     || log_error "helm no encontrado. Ejecuta: ./install.sh"
log_success "helm encontrado: $(helm version --short)"

command -v python3 &>/dev/null  || log_error "python3 no encontrado."
log_success "python3 encontrado: $(python3 --version)"

minikube status | grep -q "Running" \
  || log_error "Minikube no está corriendo. Ejecuta: minikube start --cpus=4 --memory=8192"
log_success "Minikube está activo"

kubectl get storageclass standard &>/dev/null \
  || log_error "StorageClass 'standard' no encontrada."
log_success "StorageClass 'standard' disponible"

# Verificar que setup.sh fue ejecutado (debe existir .env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  log_error ".env no encontrado. Ejecuta primero: ./setup.sh"
fi
log_success ".env encontrado — contraseñas configuradas"

echo ""
log_success "Todos los requisitos previos cumplidos"
echo ""
