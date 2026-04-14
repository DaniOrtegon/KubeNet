#!/bin/bash
# ============================================================
# 10-cleanup.sh — Eliminar todo el despliegue de KubeNet
#
# BUG CORREGIDO: el cleanup original no eliminaba cert-manager
# ni keda, dejando Helm releases y CRDs huérfanos que causaban
# problemas en re-deploys sin minikube delete.
#
# Este script limpia TODO lo que deploy.sh instala:
#   - Namespaces de la app (wordpress, databases, monitoring, storage, velero)
#   - Ingress Controller (ingress-nginx)
#   - kube-state-metrics
#   - Sealed Secrets Controller
#   - cert-manager (via Helm)
#   - KEDA (via Helm)
#   - ClusterRoles del proyecto
#   - PersistentVolumes huérfanos
#   - /etc/hosts
#   - Servicio systemd del tunnel
#
# USO:
#   ./scripts/10-cleanup.sh
#   ./scripts/10-cleanup.sh --force   # no pide confirmación
# ============================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Confirmación interactiva (saltar con --force)
if [ "$1" != "--force" ]; then
  echo ""
  echo -e "${RED}============================================================${NC}"
  echo -e "${RED}   CLEANUP — Esto eliminará TODO el despliegue de KubeNet${NC}"
  echo -e "${RED}============================================================${NC}"
  echo ""
  echo -e "${YELLOW}  Se eliminarán: namespaces, PVCs, PVs, Helm releases,${NC}"
  echo -e "${YELLOW}  ClusterRoles, Ingress Controller, cert-manager, KEDA...${NC}"
  echo ""
  read -rp "  ¿Continuar? (escribe 'si' para confirmar): " CONFIRM
  if [ "$CONFIRM" != "si" ]; then
    echo "Cancelado."
    exit 0
  fi
fi

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}   CLEANUP — Eliminando despliegue KubeNet${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# Escalar a 0 antes de borrar (evita errores de mount en PVCs)
# ------------------------------------------------------------
log_info "Escalando deployments y statefulsets a 0..."
for ns in wordpress databases monitoring storage; do
  kubectl scale deployment  --all -n $ns --replicas=0 2>/dev/null || true
  kubectl scale statefulset --all -n $ns --replicas=0 2>/dev/null || true
done
sleep 5

# ------------------------------------------------------------
# PVCs — parchear finalizers para forzar borrado
# ------------------------------------------------------------
log_info "Eliminando PVCs..."
for ns in wordpress databases monitoring storage; do
  for pvc in $(kubectl get pvc -n $ns -o name 2>/dev/null); do
    kubectl patch $pvc -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete $pvc -n $ns --grace-period=0 --force 2>/dev/null || true
  done
done

# ------------------------------------------------------------
# Namespaces de la aplicación
# ------------------------------------------------------------
log_info "Eliminando namespaces de la aplicación..."
for ns in wordpress databases monitoring security storage velero; do
  delete_namespace_safe "$ns" 20
  echo ""
done

# ------------------------------------------------------------
# Ingress Controller
# ------------------------------------------------------------
log_info "Eliminando Ingress Controller..."
delete_namespace_safe "ingress-nginx" 20
echo ""

# ------------------------------------------------------------
# kube-state-metrics
# ------------------------------------------------------------
log_info "Eliminando kube-state-metrics..."
kubectl delete deployment     kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete service        kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete serviceaccount kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrole        kube-state-metrics --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding kube-state-metrics --ignore-not-found=true 2>/dev/null || true
log_success "kube-state-metrics eliminado"

# ------------------------------------------------------------
# Sealed Secrets Controller
# ------------------------------------------------------------
log_info "Eliminando Sealed Secrets Controller..."
kubectl delete -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.26.3/controller.yaml" \
  --ignore-not-found=true 2>/dev/null || true
log_success "Sealed Secrets Controller eliminado"

# ------------------------------------------------------------
# cert-manager (Helm release + namespace)
# BUG CORREGIDO: el cleanup original no lo eliminaba,
# dejando CRDs de cert-manager y el namespace huérfanos.
# ------------------------------------------------------------
log_info "Eliminando cert-manager..."
helm uninstall cert-manager -n cert-manager 2>/dev/null \
  && log_success "Helm release cert-manager eliminado" \
  || log_warn "cert-manager no estaba instalado via Helm (o ya fue eliminado)"
delete_namespace_safe "cert-manager" 20
echo ""
# Eliminar CRDs de cert-manager para dejar el clúster limpio
kubectl delete crd \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io \
  --ignore-not-found=true 2>/dev/null || true
log_success "CRDs cert-manager eliminados"

# ------------------------------------------------------------
# KEDA (Helm release + namespace)
# BUG CORREGIDO: el cleanup original no eliminaba KEDA.
# ------------------------------------------------------------
log_info "Eliminando KEDA..."
helm uninstall keda -n keda 2>/dev/null \
  && log_success "Helm release KEDA eliminado" \
  || log_warn "KEDA no estaba instalado via Helm (o ya fue eliminado)"
delete_namespace_safe "keda" 20
echo ""

# ------------------------------------------------------------
# ClusterRoles del proyecto (Prometheus, Promtail)
# ------------------------------------------------------------
log_info "Eliminando ClusterRoles del proyecto..."
kubectl delete clusterrole        prometheus --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding prometheus --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrole        promtail   --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding promtail   --ignore-not-found=true 2>/dev/null || true
log_success "ClusterRoles eliminados"

# ------------------------------------------------------------
# PersistentVolumes huérfanos
# ------------------------------------------------------------
log_info "Eliminando PersistentVolumes huérfanos..."
for pv in $(kubectl get pv -o name 2>/dev/null); do
  kubectl patch $pv -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  kubectl delete $pv --grace-period=0 --force 2>/dev/null || true
done
log_success "PersistentVolumes eliminados"

# ------------------------------------------------------------
# Datos de Prometheus en Minikube
# ------------------------------------------------------------
log_info "Limpiando datos de Prometheus en Minikube..."
minikube ssh "sudo rm -rf /tmp/hostpath-provisioner/monitoring/ 2>/dev/null; echo ok" 2>/dev/null || true

# ------------------------------------------------------------
# Servicio systemd minikube-tunnel
# ------------------------------------------------------------
log_info "Deteniendo servicio minikube-tunnel..."
sudo systemctl stop   minikube-tunnel.service 2>/dev/null || true
sudo systemctl disable minikube-tunnel.service 2>/dev/null || true
pkill -f "minikube tunnel" 2>/dev/null || true
log_success "Servicio tunnel detenido"

# ------------------------------------------------------------
# /etc/hosts
# ------------------------------------------------------------
log_info "Limpiando /etc/hosts..."
sudo sed -i '/wp-k8s\.local/d'               /etc/hosts
sudo sed -i '/grafana\.monitoring\.local/d'   /etc/hosts
sudo sed -i '/prometheus\.monitoring\.local/d' /etc/hosts
sudo sed -i '/minio\.storage\.local/d'        /etc/hosts
log_success "/etc/hosts limpiado"

# ------------------------------------------------------------
# Reiniciar Metrics Server (evita estado corrupto en re-deploy)
# ------------------------------------------------------------
log_info "Reiniciando Metrics Server..."
kubectl rollout restart deployment metrics-server -n kube-system 2>/dev/null || true
sleep 5
kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found=true 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ Cleanup completado${NC}"
echo ""
echo -e "${BLUE}Opciones para volver a desplegar:${NC}"
echo -e "  Re-deploy completo:  ${GREEN}./deploy.sh${NC}"
echo -e "  Reset total:         ${GREEN}minikube stop && minikube delete && minikube start --cpus=4 --memory=8192${NC}"
echo ""
