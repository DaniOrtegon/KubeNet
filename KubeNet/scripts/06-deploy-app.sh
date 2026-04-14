#!/bin/bash
# ============================================================
# 06-deploy-app.sh — WordPress + TLS + Ingress + Autoscaling
#
# Despliega en orden:
#   1. WordPress (Deployment + Service)
#   2. NetworkPolicies (default-deny + reglas explícitas)
#   3. ClusterIssuers cert-manager + Certificados TLS
#   4. Ingress con TLS
#   5. KEDA ScaledObject (autoscaling por req/s + CPU)
#   6. PodDisruptionBudget
#   7. ResourceQuota + LimitRange
#
# USO:
#   ./scripts/06-deploy-app.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K8S_DIR="$SCRIPT_DIR/k8s"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [06] App: WordPress + TLS + Ingress + Autoscaling${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. WordPress
# ------------------------------------------------------------
apply_file "$K8S_DIR/app/wordpress.yaml" "Deployment + Service WordPress"
wait_for_deployment "wordpress" "wordpress" 300

# ------------------------------------------------------------
# 2. NetworkPolicies
# Se aplican DESPUÉS de WordPress para no bloquear el init
# ------------------------------------------------------------
apply_file "$K8S_DIR/core/network-policy.yaml" "NetworkPolicies (default-deny + reglas explícitas)"

# ------------------------------------------------------------
# 3. cert-manager: ClusterIssuers + Certificados TLS
# ------------------------------------------------------------
apply_cert_manager_config() {
  if kubectl get clusterissuer ca-issuer &>/dev/null; then
    log_success "ClusterIssuers ya configurados"
  else
    apply_file "$K8S_DIR/edge/cert-manager.yaml" "ClusterIssuers + Certificados TLS"
  fi

  log_info "Esperando certificado wordpress-tls..."
  local retries=0
  until kubectl get certificate wordpress-tls -n wordpress \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null | grep -q "True"; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_warn "Certificado wordpress-tls tardando — continuando" && break
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "Certificados TLS listos"
}

apply_cert_manager_config
echo ""

# ------------------------------------------------------------
# 4. Ingress con TLS
# ------------------------------------------------------------
apply_file "$K8S_DIR/edge/ingress.yaml" "Ingress con TLS"

# ------------------------------------------------------------
# 5. KEDA ScaledObject (reemplaza el HPA clásico)
# ------------------------------------------------------------
if kubectl get scaledobject wordpress-scaledobject -n wordpress &>/dev/null; then
  log_success "KEDA ScaledObject ya existe — saltando"
else
  kubectl delete hpa wordpress-hpa -n wordpress 2>/dev/null || true
  apply_file "$K8S_DIR/app/keda-wordpress.yaml" "KEDA ScaledObject WordPress (min:2 max:7)"
fi

# ------------------------------------------------------------
# 6. PodDisruptionBudget
# ------------------------------------------------------------
apply_file "$K8S_DIR/core/pdb.yaml" "PodDisruptionBudget WordPress"

# ------------------------------------------------------------
# 7. ResourceQuota + LimitRange
# ------------------------------------------------------------
apply_file "$K8S_DIR/core/resource-quota.yaml" "ResourceQuota y LimitRange"

echo ""
log_success "[06] Aplicación desplegada correctamente"
echo ""
