#!/bin/bash
# =============================================================
#  start_all.sh — Arranque seguro del clúster KubeNet
#  Ruta: /home/isard/KubeNet/start_all.sh
# =============================================================
set -uo pipefail

# --- COLORES ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()    { echo -e "${GREEN}   ✅ $*${NC}"; }
warn()  { echo -e "${YELLOW}   ⚠️  $*${NC}"; }
fail()  { echo -e "${RED}   ❌ $*${NC}"; }
info()  { echo -e "${CYAN}   ℹ️  $*${NC}"; }

# --- CONFIG ---
DOMAINS=(
    "wp-k8s.local"
    "prometheus.monitoring.local"
    "grafana.monitoring.local"
    "minio.storage.local"
)
CRITICAL_NAMESPACES=("cert-manager" "databases" "ingress-nginx" "keda" "monitoring" "storage" "velero" "wordpress")

echo ""
echo "=================================================="
echo "   🚀 KubeNet — Arranque del clúster"
echo "=================================================="

# =============================================================
# [ 1/7 ] ARRANCAR MINIKUBE
# =============================================================
echo "[ 1/7 ] Comprobando Minikube..."
STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")
if [ "$STATUS" != "Running" ]; then
    warn "Minikube no está corriendo. Arrancando..."
    minikube start || { fail "No se pudo arrancar Minikube"; exit 1; }
    ok "Minikube arrancado"
else
    ok "Minikube ya estaba corriendo"
fi

# =============================================================
# [ 2/7 ] FORZAR DNS Y TUNNEL
# =============================================================
echo ""
echo "[ 2/7 ] Configurando conectividad..."

# DNS del nodo
minikube ssh "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf" > /dev/null
ok "DNS 8.8.8.8 configurado en el nodo"

# Parchear CoreDNS para que use 8.8.8.8 directamente y no herede /etc/resolv.conf
kubectl patch configmap -n kube-system coredns --type merge -p \
'{"data":{"Corefile":".:53 {\n    log\n    errors\n    health {\n       lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n       fallthrough in-addr.arpa ip6.arpa\n       ttl 30\n    }\n    prometheus :9153\n    hosts {\n       192.168.49.1 host.minikube.internal\n       fallthrough\n    }\n    forward . 8.8.8.8 8.8.4.4 {\n       max_concurrent 1000\n    }\n    cache 30 {\n       disable success cluster.local\n       disable denial cluster.local\n    }\n    loop\n    reload\n    loadbalance\n}\n"}}' > /dev/null 2>&1
kubectl rollout restart deployment/coredns -n kube-system > /dev/null 2>&1
kubectl rollout status deployment/coredns -n kube-system --timeout=60s > /dev/null 2>&1
ok "CoreDNS parcheado con nameserver 8.8.8.8"

# Limpieza y arranque de tunnel
sudo pkill -f "minikube tunnel" 2>/dev/null || true
sudo rm -f $HOME/.minikube/tunnels.json
nohup minikube tunnel > /tmp/minikube-tunnel.log 2>&1 &
info "Tunnel iniciado en segundo plano"

# =============================================================
# [ 3/7 ] ACTUALIZAR /ETC/HOSTS
# =============================================================
echo ""
echo "[ 3/7 ] Actualizando /etc/hosts..."
TUNNEL_IP=""
for i in {1..10}; do
    TUNNEL_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [ -n "$TUNNEL_IP" ] && [ "$TUNNEL_IP" != "pending" ] && break
    sleep 2
done

[ -z "$TUNNEL_IP" ] && TUNNEL_IP=$(minikube ip)

for DOMAIN in "${DOMAINS[@]}"; do
    sudo sed -i "/$DOMAIN/d" /etc/hosts
    echo "$TUNNEL_IP $DOMAIN" | sudo tee -a /etc/hosts > /dev/null
done
ok "Hosts actualizados con IP: $TUNNEL_IP"

# =============================================================
# [ 4/7 ] REINICIAR SERVICIOS PARA REFRESCAR SECRETS
# =============================================================
echo ""
echo "[ 4/7 ] Refrescando servicios dependientes de secrets..."
kubectl rollout restart deployment -n storage minio > /dev/null 2>&1 && ok "MinIO reiniciado"
kubectl rollout restart deployment -n monitoring grafana > /dev/null 2>&1 && ok "Grafana reiniciado"

# Sincronizar credenciales de MinIO en el Secret de Velero
MINIO_USER=$(kubectl get secret minio-secret -n storage \
  -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
MINIO_PASS=$(kubectl get secret minio-secret -n storage \
  -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -n "$MINIO_USER" ] && [ -n "$MINIO_PASS" ]; then
    kubectl create secret generic velero \
      -n velero \
      --from-literal=cloud="[default]
aws_access_key_id=${MINIO_USER}
aws_secret_access_key=${MINIO_PASS}" \
      --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
    kubectl rollout restart deployment/velero -n velero > /dev/null 2>&1
    ok "Velero secret actualizado y pod reiniciado"
else
    warn "No se encontraron credenciales de MinIO — Velero no se ha actualizado"
fi

# =============================================================
# [ 5/7 ] SINCRONIZACIÓN DE CREDENCIALES (GRAFANA)
# =============================================================
echo ""
echo "[ 5/7 ] Sincronizando base de datos de Grafana..."
info "Esperando a que el pod esté listo..."
kubectl rollout status deployment -n monitoring grafana --timeout=60s > /dev/null 2>&1

GRAFANA_PASS=$(kubectl get secret -n monitoring grafana-secret -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

if [ -n "$GRAFANA_PASS" ]; then
    kubectl exec -n monitoring deployment/grafana -- \
        grafana-cli admin reset-admin-password "$GRAFANA_PASS" > /dev/null 2>&1 \
        && ok "Password de Grafana actualizada a: $GRAFANA_PASS" \
        || warn "No se pudo ejecutar el reset. Revisa manualmente."
else
    fail "No se encontró el secret de Grafana. Ejecuta ./setup.sh primero."
fi

# =============================================================
# [ 6/7 ] LIMPIEZA DE PODS HUÉRFANOS
# =============================================================
echo ""
echo "[ 6/7 ] Limpiando pods con errores..."
kubectl get pods -A --no-headers | awk '$4 ~ /BackOff|Error|ErrImage/ {print $1" "$2}' | while read ns pod; do
    kubectl delete pod -n $ns $pod --ignore-not-found > /dev/null
    warn "Eliminado pod fallido: $ns/$pod"
done
ok "Limpieza terminada"

# =============================================================
# [ 7/7 ] RESUMEN FINAL
# =============================================================
echo ""
echo "[ 7/7 ] Estado final del clúster:"
echo ""
kubectl get pods -A --no-headers | grep -E "$(IFS='|'; echo "${CRITICAL_NAMESPACES[*]}")" | awk '{printf "  %-15s %-40s %-12s\n", $1, $2, $4}'

echo ""
echo "=================================================="
echo -e "${GREEN}  🎉 ¡Clúster KubeNet listo!${NC}"
echo "=================================================="
echo "  🌐 WordPress  : https://wp-k8s.local"
echo "  📊 Grafana    : https://grafana.monitoring.local (User: admin)"
echo "  🗄️  MinIO      : https://minio.storage.local"
echo "=================================================="
