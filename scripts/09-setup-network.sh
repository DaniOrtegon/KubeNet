#!/bin/bash
# ============================================================
# 09-setup-network.sh — VERSIÓN DINÁMICA E INFALIBLE
# ============================================================

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [09] Red: Tunnel + /etc/hosts (Auto-Discovery)${NC}"
echo -e "${BLUE}============================================================${NC}"

REAL_USER="isard"
USER_HOME="/home/$REAL_USER"
MINIKUBE_BIN=$(which minikube)

setup_tunnel_service() {
  echo -e "[INFO] Configurando servicio de túnel..."
  sudo pkill -f "minikube tunnel" || true
  
  sudo tee /etc/systemd/system/minikube-tunnel.service > /dev/null <<UNIT
[Unit]
Description=Minikube Tunnel Service
After=network.target docker.service

[Service]
Type=simple
User=root
Environment="HOME=$USER_HOME"
Environment="KUBECONFIG=$USER_HOME/.kube/config"
ExecStart=$MINIKUBE_BIN tunnel --cleanup
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable minikube-tunnel.service
  sudo systemctl restart minikube-tunnel.service
  echo -e "${GREEN}[OK] Servicio de túnel activo.${NC}"
}

update_hosts() {
  echo -e "[INFO] Detectando IP y dominios..."
  
  # 1. Detectar IP (Prioridad: External IP -> Minikube IP)
  local ip=""
  ip=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "[WARN] IP de túnel no lista, usando IP del nodo Minikube..."
    ip=$(minikube ip)
  fi

  # 2. Detectar TODOS los dominios configurados en los Ingress del clúster
  # Esto busca en todos los namespaces y extrae los 'host' de las reglas
  local hosts=$(kubectl get ingress -A -o jsonpath='{.items[*].spec.rules[*].host}')

  if [ -z "$hosts" ]; then
    echo -e "${RED}[ERROR] No se han encontrado dominios en los Ingress.${NC}"
    exit 1
  fi

  echo -e "${GREEN}[OK] IP: $ip${NC}"
  echo -e "${GREEN}[OK] Dominios: $hosts${NC}"

  # 3. Limpiar entradas viejas y escribir nuevas una a una para evitar truncado
  sudo sed -i '/\.local\|wp-k8s/d' /etc/hosts
  
  for h in $hosts; do
    echo "$ip $h" | sudo tee -a /etc/hosts > /dev/null
  done
  
  echo -e "${GREEN}[OK] /etc/hosts actualizado sin errores.${NC}"
}

# Ejecución
setup_tunnel_service
sleep 2 # Breve pausa para el túnel
update_hosts

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}   ACCESO MULTI-SERVICIO LISTO:${NC}"
for h in $(kubectl get ingress -A -o jsonpath='{.items[*].spec.rules[*].host}'); do
  echo -e "${GREEN}   - https://$h${NC}"
done
echo -e "${GREEN}============================================================${NC}"


