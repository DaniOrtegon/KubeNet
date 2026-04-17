#!/bin/bash

# --- 1. CONFIGURACIÓN DE RUTAS ---
# Nos aseguramos de saber dónde estamos
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$ROOT_DIR"

echo "----------------------------------------------------"
echo "🚀 INICIANDO REPARACIÓN Y ARRANQUE DE KUBENET"
echo "----------------------------------------------------"

# --- 2. VERIFICAR MINIKUBE ---
NEW_IP=$(minikube ip 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "❌ Minikube no está corriendo. Iniciándolo..."
    minikube start
    NEW_IP=$(minikube ip)
fi
echo "✅ IP de Minikube: $NEW_IP"

# --- 3. ACTUALIZAR /ETC/HOSTS ---
DOMAINS=("wordpress.local" "grafana.monitoring.local" "minio.storage.local")
echo "🔧 Actualizando /etc/hosts (requiere sudo)..."
for DOMAIN in "${DOMAINS[@]}"; do
    sudo sed -i "/$DOMAIN/d" /etc/hosts
    echo "$NEW_IP $DOMAIN" | sudo tee -a /etc/hosts > /dev/null
    echo "   ✅ $DOMAIN -> $NEW_IP"
done

# --- 4. REPARAR DNS INTERNO ---
echo "🔧 Reparando DNS dentro del clúster..."
minikube ssh "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf" > /dev/null

# --- 5. CARGAR IMAGEN DE KEDA (SOLUCIÓN IMAGEPULLBACKOFF) ---
echo "📦 Cargando imagen de KEDA manualmente..."
# La bajamos a tu Debian primero
docker pull ghcr.io/kedacore/keda-admission-webhooks:2.19.0
# La inyectamos en Minikube
minikube image load ghcr.io/kedacore/keda-admission-webhooks:2.19.0

# --- 6. LIMPIAR PODS BLOQUEADOS ---
echo "🧹 Limpiando pods con errores..."
# KEDA
kubectl delete pods -n keda -l app.kubernetes.io/name=keda-admission-webhooks --ignore-not-found
# REDIS (por si acaso)
kubectl delete pods -n databases -l app.kubernetes.io/name=redis --ignore-not-found

# --- 7. VERIFICACIÓN FINAL ---
echo "----------------------------------------------------"
echo "📊 ESTADO DE LOS SERVICIOS CRÍTICOS:"
echo "----------------------------------------------------"
kubectl get pods -A | grep -E "grafana|keda|redis|wordpress"

echo ""
echo "🎉 ¡Todo listo! Acceso:"
echo "🔗 Grafana: http://grafana.monitoring.local"
echo "🔗 WordPress: http://wordpress.local"
echo "----------------------------------------------------"
