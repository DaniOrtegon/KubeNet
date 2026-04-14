#!/bin/bash
# ============================================================
# 09-setup-network.sh — Tunnel + /etc/hosts
#
# Configura el acceso local a los servicios de KubeNet:
#   1. minikube tunnel como servicio systemd (con fallback a nohup)
#   2. /etc/hosts con la IP del Ingress Controller
#
# Sin este paso, las URLs locales (wp-k8s.local, etc.) no resuelven.
#
# USO:
#   ./scripts/09-setup-network.sh
# ============================================================

set -e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [09] Red: Tunnel + /etc/hosts${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. minikube tunnel como servicio systemd
#
# minikube tunnel necesita privilegios de red (abre puertos 80/443).
# Lo configuramos como servicio systemd para que arranque solo
# tras reinicios. Si systemd falla (p.ej. en WSL), usamos nohup
# como fallback.
# ------------------------------------------------------------
setup_tunnel_service() {
  local SERVICE_FILE="/etc/systemd/system/minikube-tunnel.service"
  local CURRENT_USER
  CURRENT_USER=$(whoami)
  local CURRENT_HOME
  CURRENT_HOME=$(eval echo ~"$CURRENT_USER")
  local MINIKUBE_PATH
  MINIKUBE_PATH=$(which minikube)

  log_info "Configurando minikube tunnel como servicio systemd..."

  sudo tee "$SERVICE_FILE" > /dev/null << UNIT
[Unit]
Description=Minikube Tunnel
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=${CURRENT_USER}
Environment="HOME=${CURRENT_HOME}"
Environment="KUBECONFIG=${CURRENT_HOME}/.kube/config"
ExecStartPre=/bin/sleep 5
ExecStart=${MINIKUBE_PATH} tunnel
ExecStop=/usr/bin/pkill -f "minikube tunnel"
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable minikube-tunnel.service
  sudo systemctl restart minikube-tunnel.service

  sleep 5
  if sudo systemctl is-active --quiet minikube-tunnel.service; then
    log_success "Servicio minikube-tunnel activo"
  else
    log_warn "Servicio systemd no arrancó (¿WSL o entorno sin systemd?)"
    log_warn "Lanzando minikube tunnel en segundo plano con nohup..."
    # Matar instancia previa si existe
    pkill -f "minikube tunnel" 2>/dev/null || true
    sleep 2
    nohup minikube tunnel > /tmp/minikube-tunnel.log 2>&1 &
    sleep 5
    log_info "Tunnel en segundo plano — log en /tmp/minikube-tunnel.log"
  fi
}

# ------------------------------------------------------------
# 2. Obtener IP del Ingress Controller y actualizar /etc/hosts
# ------------------------------------------------------------
update_hosts() {
  log_info "Obteniendo IP externa del Ingress Controller..."

  local retries=0
  local EXTERNAL_IP=""

  until [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; do
    retries=$((retries + 1))
    if [ $retries -ge 36 ]; then
      log_error "No se asignó EXTERNAL-IP en 3 minutos. Asegúrate de que minikube tunnel está corriendo."
    fi
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" = "<pending>" ] && echo -n "." && sleep 5
  done
  echo ""
  log_success "EXTERNAL-IP obtenida: $EXTERNAL_IP"

  # Limpiar entradas anteriores de KubeNet
  sudo sed -i '/wp-k8s\.local/d'               /etc/hosts
  sudo sed -i '/grafana\.monitoring\.local/d'   /etc/hosts
  sudo sed -i '/prometheus\.monitoring\.local/d' /etc/hosts
  sudo sed -i '/minio\.storage\.local/d'        /etc/hosts

  # Añadir entradas nuevas
  echo "$EXTERNAL_IP wp-k8s.local"               | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP grafana.monitoring.local"    | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP prometheus.monitoring.local" | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP minio.storage.local"         | sudo tee -a /etc/hosts > /dev/null

  log_success "/etc/hosts actualizado con IP $EXTERNAL_IP"
}

setup_tunnel_service
echo ""
update_hosts

echo ""
log_success "[09] Red configurada correctamente"
echo ""
