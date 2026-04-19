#!/bin/bash
# =============================================================
#  start_all.sh — Arranque seguro del clúster KubeNet
#  Ruta: /home/isard/KubeNet/scripts/start_all.sh
#  Uso:  ./scripts/start_all.sh
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
CRITICAL_NAMESPACES=(
    "cert-manager"
    "databases"
    "ingress-nginx"
    "keda"
    "monitoring"
    "storage"
    "velero"
    "wordpress"
)
CRITICAL_IMAGES=(
    "ghcr.io/kedacore/keda-admission-webhooks:2.19.0"
    "ghcr.io/kedacore/keda-operator:2.19.0"
    "ghcr.io/kedacore/keda-metrics-apiserver:2.19.0"
    "minio/mc:RELEASE.2025-08-13T08-35-41Z"
    "velero/velero:v1.12.4"
)

echo ""
echo "=================================================="
echo "  🚀 KubeNet — Arranque del clúster"
echo "=================================================="
echo ""

# =============================================================
# [ 1/7 ] ARRANCAR MINIKUBE
# =============================================================
echo "[ 1/7 ] Comprobando Minikube..."
STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")
if [ "$STATUS" != "Running" ]; then
    warn "Minikube no está corriendo. Arrancando..."
    ATTEMPTS=0
    until minikube start 2>/dev/null; do
        ATTEMPTS=$((ATTEMPTS + 1))
        if [ $ATTEMPTS -ge 3 ]; then
            fail "Minikube no pudo arrancar tras 3 intentos. Revisa 'minikube logs'."
            exit 1
        fi
        warn "Intento $ATTEMPTS fallido, reintentando en 10s..."
        sleep 10
    done
    ok "Minikube arrancado"
else
    ok "Minikube ya estaba corriendo"
fi

# Esperar a que el nodo esté Ready antes de continuar
info "Esperando a que el nodo esté Ready..."
kubectl wait --for=condition=Ready node/minikube --timeout=60s > /dev/null 2>&1 \
    && ok "Nodo Ready" \
    || { fail "El nodo no está Ready tras 60s. Revisa 'kubectl describe node minikube'."; exit 1; }

# =============================================================
# [ 2/7 ] ARREGLAR DNS DENTRO DEL NODO
# =============================================================
echo ""
echo "[ 2/7 ] Forzando DNS en el nodo minikube..."
minikube ssh "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf" > /dev/null
ok "DNS forzado → 8.8.8.8"

# =============================================================
# [ 3/7 ] TUNNEL — PERMISOS Y ARRANQUE
# =============================================================
echo ""
echo "[ 3/7 ] Arrancando minikube tunnel..."

# Arreglar permisos
sudo chown -R $USER $HOME/.minikube
chmod -R u+wrx $HOME/.minikube

# Limpiar lockfiles de tunnels anteriores
sudo rm -f $HOME/.minikube/tunnels.json
sudo rm -f $HOME/.minikube/profiles/minikube/.tunnel_lock

# Matar tunnel previo si existe
sudo pkill -f "minikube tunnel" 2>/dev/null || true
sleep 2

# Lanzar tunnel en background
nohup minikube tunnel > /tmp/minikube-tunnel.log 2>&1 &
info "Esperando IP del tunnel..."

# Esperar hasta que EXTERNAL-IP deje de ser <pending>
TUNNEL_IP=""
ATTEMPTS=0
until [ -n "$TUNNEL_IP" ] && [ "$TUNNEL_IP" != "pending" ]; do
    sleep 3
    TUNNEL_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge 20 ]; then
        warn "Timeout esperando IP del tunnel. Usando minikube ip como fallback."
        TUNNEL_IP=$(minikube ip)
        break
    fi
done
ok "IP del tunnel: $TUNNEL_IP"

# =============================================================
# [ 4/7 ] ACTUALIZAR /ETC/HOSTS CON IP DEL TUNNEL
# =============================================================
echo ""
echo "[ 4/7 ] Actualizando /etc/hosts..."
for DOMAIN in "${DOMAINS[@]}"; do
    sudo sed -i "/$DOMAIN/d" /etc/hosts
    echo "$TUNNEL_IP $DOMAIN" | sudo tee -a /etc/hosts > /dev/null
    ok "$DOMAIN → $TUNNEL_IP"
done

# =============================================================
# [ 5/7 ] VERIFICAR PERSISTENTVOLUMES
# =============================================================
echo ""
echo "[ 5/7 ] Verificando PersistentVolumes..."
BROKEN_PVS=$(kubectl get pv --no-headers 2>/dev/null \
    | awk '$5 ~ /Lost|Failed|Pending/ {print $1" ("$5")"}')
BROKEN_PVCS=$(kubectl get pvc -A --no-headers 2>/dev/null \
    | awk '$4 ~ /Lost|Pending/ {print $1"/"$2" ("$4")"}')

if [ -z "$BROKEN_PVS" ] && [ -z "$BROKEN_PVCS" ]; then
    ok "Todos los PersistentVolumes están Bound"
else
    [ -n "$BROKEN_PVS" ]  && fail "PVs en mal estado: $BROKEN_PVS"
    [ -n "$BROKEN_PVCS" ] && fail "PVCs en mal estado: $BROKEN_PVCS"
    warn "Los PVs rotos pueden afectar a MariaDB y Redis. Puede requerir intervención manual."
fi

# =============================================================
# [ 6/7 ] LIMPIAR PODS CON ERRORES
# =============================================================
echo ""
echo "[ 6/7 ] Buscando pods con errores..."
FOUND=0

# ImagePullBackOff / ErrImagePull
PULL_ERRORS=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 ~ /ImagePullBackOff|ErrImagePull/ {print $1" "$2}')
if [ -n "$PULL_ERRORS" ]; then
    while IFS= read -r line; do
        NS=$(echo "$line" | awk '{print $1}')
        POD=$(echo "$line" | awk '{print $2}')
        warn "ImagePullBackOff: $NS/$POD — eliminando"
        kubectl delete pod -n "$NS" "$POD" --ignore-not-found > /dev/null
        FOUND=$((FOUND + 1))
    done <<< "$PULL_ERRORS"
fi

# CrashLoopBackOff
CRASH_ERRORS=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 ~ /CrashLoopBackOff/ {print $1" "$2}')
if [ -n "$CRASH_ERRORS" ]; then
    while IFS= read -r line; do
        NS=$(echo "$line" | awk '{print $1}')
        POD=$(echo "$line" | awk '{print $2}')
        warn "CrashLoopBackOff: $NS/$POD — eliminando"
        kubectl delete pod -n "$NS" "$POD" --ignore-not-found > /dev/null
        FOUND=$((FOUND + 1))
    done <<< "$CRASH_ERRORS"
fi

# Rollouts atascados
info "Comprobando rollouts atascados..."
for NS in "${CRITICAL_NAMESPACES[@]}"; do
    STUCK=$(kubectl get replicasets -n "$NS" --no-headers 2>/dev/null \
        | awk '$2 > 0 && $4 == 0 {print $1}')
    if [ -n "$STUCK" ]; then
        warn "ReplicaSet huérfano en $NS: $STUCK"
        kubectl delete replicaset -n "$NS" $STUCK --ignore-not-found > /dev/null
        FOUND=$((FOUND + 1))
    fi
done

# Jobs fallidos
FAILED_JOBS=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 == "Error" {print $1" "$2}')
if [ -n "$FAILED_JOBS" ]; then
    while IFS= read -r line; do
        NS=$(echo "$line" | awk '{print $1}')
        POD=$(echo "$line" | awk '{print $2}')
        warn "Job fallido: $NS/$POD — eliminando para reintento"
        kubectl delete pod -n "$NS" "$POD" --ignore-not-found > /dev/null
        FOUND=$((FOUND + 1))
    done <<< "$FAILED_JOBS"
fi

if [ $FOUND -eq 0 ]; then
    ok "No hay pods con errores"
else
    ok "$FOUND pod(s) eliminados — el clúster los recreará automáticamente"
fi

# =============================================================
# [ 7/7 ] VERIFICACIÓN FINAL
# =============================================================
echo ""
echo "[ 7/7 ] Estado del clúster..."
echo ""

UNHEALTHY=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4 !~ /Running|Completed/ {print}')
if [ -n "$UNHEALTHY" ]; then
    warn "Pods que aún no están Running/Completed:"
    echo "$UNHEALTHY"
else
    ok "Todos los pods están Running o Completed"
fi

# --- SINCRONIZAR PASSWORD DE GRAFANA ---
echo ""
info "Sincronizando credenciales de Grafana..."
GRAFANA_PASS=$(kubectl get secret -n monitoring grafana-secret \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

if [ -n "$GRAFANA_PASS" ]; then
    kubectl exec -n monitoring deployment/grafana -- \
        grafana-cli admin reset-admin-password "$GRAFANA_PASS" > /dev/null 2>&1 \
        && ok "Grafana password sincronizada con el secret" \
        || warn "No se pudo sincronizar Grafana — puede que aún esté arrancando"
else
    warn "No se encontró grafana-secret — ejecuta setup.sh primero"
fi

echo ""
echo "--- Namespaces críticos ---"
kubectl get pods -A --no-headers 2>/dev/null \
    | grep -E "$(IFS='|'; echo "${CRITICAL_NAMESPACES[*]}")" \
    | awk '{printf "  %-20s %-45s %-15s\n", $1, $2, $4}'

echo ""
echo "=================================================="
echo -e "${GREEN}  🎉 ¡Clúster listo!${NC}"
echo ""
echo "  🌐 WordPress   → http://wp-k8s.local"
echo "  📊 Grafana     → http://grafana.monitoring.local"
echo "  📈 Prometheus  → http://prometheus.monitoring.local"
echo "  🗄️  MinIO       → http://minio.storage.local"
echo "=================================================="
echo ""
