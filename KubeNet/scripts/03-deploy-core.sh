#!/bin/bash
# ============================================================
# 03-deploy-core.sh — Namespaces, Secrets, ConfigMaps, PVCs
#
# Aplica en orden:
#   1. Namespaces (con Pod Security Standards)
#   2. SealedSecrets (generados si no existen o son inválidos)
#   3. ConfigMaps
#   4. PersistentVolumeClaims
#
# USO:
#   ./scripts/03-deploy-core.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K8S_DIR="$SCRIPT_DIR/k8s"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [03] Core: Namespaces, Secrets, ConfigMaps, PVCs${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# 1. Namespaces
# ------------------------------------------------------------
apply_file "$K8S_DIR/core/namespace.yaml" "Namespaces"
sleep 2

# ------------------------------------------------------------
# 2. SealedSecrets
#
# BUG CORREGIDO: el script original guardaba los SealedSecrets
# generados en el directorio raíz del repo. Ahora se guardan en
# secrets/ para mantener el repo ordenado.
#
# Si los SealedSecrets ya existen, se validan contra el clúster
# actual. Si son incompatibles (p.ej. tras minikube delete), se
# hace backup y se regeneran automáticamente.
# ------------------------------------------------------------
generate_sealed_secrets() {
  local SECRETS_DIR="$SCRIPT_DIR/secrets"
  mkdir -p "$SECRETS_DIR"

  local SEALED_FILES=(
    "$SECRETS_DIR/sealed-mariadb-secret-databases.yaml"
    "$SECRETS_DIR/sealed-mariadb-secret-wordpress.yaml"
    "$SECRETS_DIR/sealed-redis-secret-databases.yaml"
    "$SECRETS_DIR/sealed-redis-secret-wordpress.yaml"
  )

  local all_exist=true
  for f in "${SEALED_FILES[@]}"; do
    [ ! -f "$f" ] && all_exist=false && break
  done

  if $all_exist; then
    log_info "SealedSecrets encontrados — verificando compatibilidad con el clúster..."
    if kubeseal --validate < "${SEALED_FILES[0]}" &>/dev/null 2>&1; then
      log_success "SealedSecrets válidos para este clúster — reutilizando"
      # Aplicarlos directamente
      for f in "${SEALED_FILES[@]}"; do
        apply_file "$f" "$(basename $f)"
      done
      return
    else
      log_warn "SealedSecrets incompatibles con este clúster (¿minikube delete reciente?)"
      local backup_dir="$SCRIPT_DIR/secrets/backup-$(date +%Y%m%d_%H%M%S)"
      mkdir -p "$backup_dir"
      for f in "${SEALED_FILES[@]}"; do
        [ -f "$f" ] && cp "$f" "$backup_dir/" && rm -f "$f"
      done
      log_info "Backup guardado en: $backup_dir/"
    fi
  fi

  # Cargar contraseñas desde .env
  if [ ! -f "$SCRIPT_DIR/.env" ]; then
    log_error ".env no encontrado. Ejecuta: ./setup.sh"
  fi

  # Exportar variables del .env de forma segura
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*#.*$ || -z "$key" ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    export "$key=$value"
  done < "$SCRIPT_DIR/.env"

  log_info "Generando SealedSecrets con kubeseal..."

  kubectl create secret generic mariadb-secret \
    --namespace databases \
    --from-literal=mariadb-root-password="${MARIADB_ROOT_PASSWORD}" \
    --from-literal=mariadb-user-password="${MARIADB_USER_PASSWORD}" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > "$SECRETS_DIR/sealed-mariadb-secret-databases.yaml" \
    || log_error "Error generando sealed-mariadb-secret-databases.yaml"
  log_success "sealed-mariadb-secret-databases.yaml generado"

  kubectl create secret generic mariadb-secret \
    --namespace wordpress \
    --from-literal=mariadb-user-password="${MARIADB_USER_PASSWORD}" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > "$SECRETS_DIR/sealed-mariadb-secret-wordpress.yaml" \
    || log_error "Error generando sealed-mariadb-secret-wordpress.yaml"
  log_success "sealed-mariadb-secret-wordpress.yaml generado"

  kubectl create secret generic redis-secret \
    --namespace databases \
    --from-literal=redis-password="${REDIS_PASSWORD}" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > "$SECRETS_DIR/sealed-redis-secret-databases.yaml" \
    || log_error "Error generando sealed-redis-secret-databases.yaml"
  log_success "sealed-redis-secret-databases.yaml generado"

  kubectl create secret generic redis-secret \
    --namespace wordpress \
    --from-literal=redis-password="${REDIS_PASSWORD}" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > "$SECRETS_DIR/sealed-redis-secret-wordpress.yaml" \
    || log_error "Error generando sealed-redis-secret-wordpress.yaml"
  log_success "sealed-redis-secret-wordpress.yaml generado"

  log_success "SealedSecrets generados en secrets/"
  log_warn "IMPORTANTE — haz backup de la clave privada del clúster:"
  log_warn "  kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master-key-backup.yaml"

  # Aplicar los SealedSecrets recién generados
  for f in "${SEALED_FILES[@]}"; do
    apply_file "$f" "$(basename $f)"
  done
}

generate_sealed_secrets
echo ""

# ------------------------------------------------------------
# 3. ConfigMaps
# ------------------------------------------------------------
apply_file "$K8S_DIR/core/configmap.yaml" "ConfigMaps"

# ------------------------------------------------------------
# 4. PVCs
# ------------------------------------------------------------
apply_file "$K8S_DIR/storage/pvc.yaml" "PersistentVolumeClaims"

echo ""
log_success "[03] Core desplegado correctamente"
echo ""
