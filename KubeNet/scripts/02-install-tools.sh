#!/bin/bash
# ============================================================
# 02-install-tools.sh — Instalar herramientas del clúster
#
# Instala y configura en orden:
#   1. Ingress Controller (nginx, baremetal)
#   2. kube-state-metrics
#   3. Metrics Server (addon Minikube)
#   4. Sealed Secrets Controller + kubeseal CLI
#   5. cert-manager (via Helm)
#   6. KEDA (via Helm)
#
# Todas las funciones son idempotentes: si la herramienta ya
# está instalada, se salta sin error.
#
# USO:
#   ./scripts/02-install-tools.sh
# ============================================================

set -e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [02] Instalando herramientas del clúster${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. Ingress Controller
# ------------------------------------------------------------
install_ingress_controller() {
  if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
      2>/dev/null | grep -q "Running"; then
    log_success "Ingress Controller ya está corriendo"
    return
  fi

  log_info "Instalando Ingress Controller nginx v1.14.1..."
  kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null
  sleep 5

  # Descarga el manifest y elimina los digests SHA256 para que use
  # los tags exactos que hemos precargado en Minikube
  curl -sL https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.1/deploy/static/provider/baremetal/deploy.yaml \
    | sed 's/@sha256:[a-f0-9]*//g' \
    | kubectl apply -f - \
    || log_error "No se pudo aplicar el manifest del Ingress Controller."

  log_info "Parcheando imagePullPolicy a Never para usar imágenes locales..."
  sleep 5
  for JOB in ingress-nginx-admission-create ingress-nginx-admission-patch; do
    kubectl patch job $JOB -n ingress-nginx --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
      2>/dev/null && log_success "Job $JOB parcheado" || true
  done
  kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
    2>/dev/null || true

  log_info "Esperando Ingress Controller (hasta 6 min)..."
  local retries=0
  until kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
      2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    if [ $retries -ge 36 ]; then
      log_warn "Ingress Controller no arrancó en 6 minutos."
      log_warn "Estado de pods:"
      kubectl get pods -n ingress-nginx 2>/dev/null || true
      log_error "Ingress Controller es requerido — abortando. Revisa los pods con: kubectl describe pods -n ingress-nginx"
    fi
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "Ingress Controller listo"

  kubectl patch svc ingress-nginx-controller -n ingress-nginx \
    -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true
  log_success "Ingress Controller configurado como LoadBalancer"
}

# ------------------------------------------------------------
# 2. kube-state-metrics
# ------------------------------------------------------------
install_kube_state_metrics() {
  if kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
    log_success "kube-state-metrics ya está instalado"
    return
  fi

  log_info "Instalando kube-state-metrics v2.10.0..."
  local BASE_URL="https://raw.githubusercontent.com/kubernetes/kube-state-metrics/v2.10.0/examples/standard"
  curl -sL "$BASE_URL/cluster-role.yaml"         | kubectl apply -f - || true
  curl -sL "$BASE_URL/cluster-role-binding.yaml" | kubectl apply -f - || true
  curl -sL "$BASE_URL/service-account.yaml"      | kubectl apply -f - || true
  curl -sL "$BASE_URL/service.yaml"              | kubectl apply -f - || true
  curl -sL "$BASE_URL/deployment.yaml" \
    | sed 's/@sha256:[a-f0-9]*//g' \
    | kubectl apply -f - || true

  sleep 5
  kubectl patch deployment kube-state-metrics -n kube-system --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
    2>/dev/null || true

  local retries=0
  until kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-state-metrics \
      2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_warn "kube-state-metrics tardando — continuando" && break
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "kube-state-metrics listo"
}

# ------------------------------------------------------------
# 3. Metrics Server
# ------------------------------------------------------------
install_metrics_server() {
  if minikube addons list | grep -q "metrics-server.*enabled"; then
    log_success "Metrics Server ya está habilitado"
  else
    log_info "Habilitando Metrics Server..."
    minikube addons enable metrics-server
    log_success "Metrics Server habilitado"
  fi
}

# ------------------------------------------------------------
# 4. Sealed Secrets Controller
# ------------------------------------------------------------
install_sealed_secrets() {
  if kubectl get deployment sealed-secrets-controller -n kube-system &>/dev/null; then
    log_success "Sealed Secrets Controller ya está instalado"
    return
  fi

  local VERSION="0.26.3"
  log_info "Cargando imagen Sealed Secrets en Minikube..."
  if ! minikube image ls 2>/dev/null | grep -qF "bitnami/sealed-secrets-controller:${VERSION}"; then
    docker pull bitnami/sealed-secrets-controller:${VERSION} \
      || log_error "No se pudo descargar sealed-secrets"
    minikube image load bitnami/sealed-secrets-controller:${VERSION} \
      || log_error "No se pudo cargar sealed-secrets en Minikube"
  fi

  log_info "Instalando Sealed Secrets Controller v${VERSION}..."
  curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/controller.yaml" \
    | sed 's/imagePullPolicy: .*/imagePullPolicy: Never/g' \
    | kubectl apply -f - \
    || log_error "No se pudo instalar Sealed Secrets Controller."

  local retries=0
  until kubectl get pods -n kube-system -l name=sealed-secrets-controller \
      2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_error "Sealed Secrets Controller no arrancó en 3 minutos."
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "Sealed Secrets Controller listo"
  log_warn "Haz backup de la clave privada:"
  log_warn "  kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master-key-backup.yaml"
}

# ------------------------------------------------------------
# 5. kubeseal CLI
# ------------------------------------------------------------
install_kubeseal() {
  if command -v kubeseal &>/dev/null; then
    log_success "kubeseal ya está instalado: $(kubeseal --version 2>&1)"
    return
  fi

  local VERSION="0.26.3"
  local ARCH="amd64"
  log_info "Instalando kubeseal CLI v${VERSION}..."
  curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/kubeseal-${VERSION}-linux-${ARCH}.tar.gz" \
    | tar xz kubeseal \
    && sudo mv kubeseal /usr/local/bin/kubeseal \
    && sudo chmod +x /usr/local/bin/kubeseal \
    || log_error "No se pudo instalar kubeseal."

  log_success "kubeseal instalado: $(kubeseal --version 2>&1)"
}

# ------------------------------------------------------------
# 6. cert-manager
# BUG CORREGIDO: la variable 'retries' se reutilizaba en dos
# bucles seguidos dentro de la misma función. En bash, 'local'
# dentro de una función solo tiene efecto la primera vez que se
# declara — el segundo 'local retries=0' era un no-op y el
# segundo bucle heredaba el valor final del primero, pudiendo
# hacer timeout inmediato. Se usan nombres distintos.
# ------------------------------------------------------------
install_cert_manager() {
  if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
    log_success "cert-manager ya está instalado"
    return
  fi

  local CM_VERSION="v1.14.4"
  local CM_IMAGES=(
    "quay.io/jetstack/cert-manager-controller:${CM_VERSION}"
    "quay.io/jetstack/cert-manager-cainjector:${CM_VERSION}"
    "quay.io/jetstack/cert-manager-webhook:${CM_VERSION}"
    "quay.io/jetstack/cert-manager-startupapicheck:${CM_VERSION}"
  )
  for IMAGE in "${CM_IMAGES[@]}"; do
    if ! minikube image ls 2>/dev/null | grep -qF "$IMAGE"; then
      docker pull "$IMAGE" || log_error "No se pudo descargar $IMAGE"
      minikube image load "$IMAGE" || log_error "No se pudo cargar $IMAGE"
    fi
  done

  if ! helm repo list 2>/dev/null | grep -q "jetstack"; then
    helm repo add jetstack https://charts.jetstack.io \
      || log_error "No se pudo añadir repo jetstack."
    helm repo update
  fi

  log_info "Instalando cert-manager ${CM_VERSION}..."
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version ${CM_VERSION} \
    --set installCRDs=true \
    --set global.leaderElection.namespace=cert-manager \
    --set image.pullPolicy=Never \
    --set webhook.image.pullPolicy=Never \
    --set cainjector.image.pullPolicy=Never \
    --set startupapicheck.image.pullPolicy=Never \
    || log_error "No se pudo instalar cert-manager."

  # --- Esperar los pods principales (retries_main) ---
  log_info "Esperando pods de cert-manager (hasta 4 min)..."
  local retries_main=0
  until [ "$(kubectl get pods -n cert-manager --field-selector=status.phase=Running \
      2>/dev/null | grep -c Running)" -ge 3 ]; do
    retries_main=$((retries_main + 1))
    [ $retries_main -ge 24 ] && log_error "cert-manager no arrancó en 4 minutos."
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "cert-manager listo"

  # --- Esperar el webhook (retries_webhook — variable separada) ---
  log_info "Esperando webhook cert-manager..."
  local retries_webhook=0
  until kubectl get pods -n cert-manager -l app.kubernetes.io/component=webhook \
      2>/dev/null | grep -q "Running"; do
    retries_webhook=$((retries_webhook + 1))
    [ $retries_webhook -ge 24 ] && log_error "Webhook cert-manager no arrancó."
    echo -n "."
    sleep 10
  done
  echo ""
  sleep 10  # margen extra para que el webhook se registre en la API
  log_success "Webhook cert-manager listo"
}

# ------------------------------------------------------------
# 7. KEDA
# ------------------------------------------------------------
install_keda() {
  if kubectl get deployment keda-operator -n keda &>/dev/null; then
    log_success "KEDA ya está instalado"
    return
  fi

  log_info "Instalando KEDA..."
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update kedacore 2>/dev/null || true
  kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  helm upgrade --install keda kedacore/keda \
    --namespace keda \
    --set image.keda.pullPolicy=Never \
    --set image.metricsApiServer.pullPolicy=Never \
    --set image.webhooks.pullPolicy=Never \
    --timeout 5m \
    || log_warn "KEDA helm install falló — continuando sin KEDA"

  wait_for_deployment "keda" "keda-operator" 300
  log_success "KEDA instalado"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------
install_ingress_controller
echo ""

install_kube_state_metrics
echo ""

install_metrics_server
echo ""

install_sealed_secrets
echo ""

install_kubeseal
echo ""

install_cert_manager
echo ""

install_keda
echo ""

log_success "[02] Herramientas del clúster instaladas correctamente"
echo ""
