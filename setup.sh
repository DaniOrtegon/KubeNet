#!/bin/bash
# ============================================================
# setup.sh — Configuración inicial de contraseñas
#
# Si no existe .env, lo genera de forma interactiva preguntando
# cada contraseña al usuario.
#
# Propaga las contraseñas como Secrets de Kubernetes via
# 'kubectl create secret --dry-run | apply' — sin tocar los
# YAMLs del proyecto ni usar sed.
#
# Los Secrets de MariaDB y Redis los gestiona 03-deploy-core.sh
# via SealedSecrets (kubeseal). Este script gestiona los de
# MinIO y Grafana, que no usan SealedSecrets.
#
# REQUISITO: el clúster debe estar arrancado antes de ejecutar
# este script (minikube start).
#
# USO:
#   ./setup.sh         # genera .env si no existe, luego aplica Secrets
#   ./deploy.sh        # despliega
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   KubeNet — Configuración de contraseñas${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ============================================================
# 1. Generar .env interactivamente si no existe
# ============================================================
if [ ! -f "$ENV_FILE" ]; then
    log_info "No se encontró .env — iniciando configuración interactiva..."
    echo ""

    read_value() {
        local var_name="$1"
        local prompt="$2"
        local min_length="${3:-3}"
        local value=""
        while [ -z "$value" ] || [ ${#value} -lt $min_length ]; do
            read -rp "  $prompt: " value
            [ -z "$value" ] && echo -e "  ${RED}No puede estar vacío.${NC}" && continue
            [ ${#value} -lt $min_length ] && echo -e "  ${RED}Mínimo $min_length caracteres.${NC}"
        done
        echo "$var_name=$value" >> "$ENV_FILE"
        export "$var_name=$value"
    }

    read_password() {
        local var_name="$1"
        local prompt="$2"
        local min_length="${3:-8}"
        local value=""
        while [ -z "$value" ] || [ ${#value} -lt $min_length ]; do
            read -rsp "  $prompt: " value
            echo ""
            [ -z "$value" ] && echo -e "  ${RED}No puede estar vacío.${NC}" && continue
            [ ${#value} -lt $min_length ] && echo -e "  ${RED}Mínimo $min_length caracteres.${NC}"
        done
        echo "$var_name=$value" >> "$ENV_FILE"
        export "$var_name=$value"
    }

    {
        echo "# .env — Contraseñas de KubeNet"
        echo "# Generado por setup.sh — NO subir al repositorio"
        echo "# Para regenerar: rm .env && ./setup.sh"
        echo ""
    } > "$ENV_FILE"

    echo -e "${YELLOW}  MariaDB${NC}"
    read_password "MARIADB_ROOT_PASSWORD"  "Contraseña root de MariaDB"
    read_password "MARIADB_USER_PASSWORD"  "Contraseña del usuario wordpress de MariaDB"
    echo ""

    echo -e "${YELLOW}  Redis${NC}"
    read_password "REDIS_PASSWORD"         "Contraseña de Redis"
    echo ""

    echo -e "${YELLOW}  MinIO${NC}"
    read_value    "MINIO_ROOT_USER"        "Usuario root de MinIO (ej: minioadmin)" 3
    read_password "MINIO_ROOT_PASSWORD"    "Contraseña root de MinIO" 8
    echo ""

    echo -e "${YELLOW}  Grafana${NC}"
    read_value    "GRAFANA_ADMIN_USER"     "Usuario admin de Grafana (ej: admin)"
    read_password "GRAFANA_ADMIN_PASSWORD" "Contraseña admin de Grafana"
    echo ""

    log_success ".env generado correctamente"
    echo ""
else
    log_info "Cargando contraseñas desde .env existente..."
fi

# ============================================================
# 2. Cargar .env
# ============================================================
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[[:space:]]*#.*$ || -z "$key" ]] && continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    export "$key=$value"
done < "$ENV_FILE"

REQUIRED_VARS=(
    MARIADB_ROOT_PASSWORD
    MARIADB_USER_PASSWORD
    REDIS_PASSWORD
    MINIO_ROOT_USER
    MINIO_ROOT_PASSWORD
    GRAFANA_ADMIN_USER
    GRAFANA_ADMIN_PASSWORD
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "La variable $var está vacía en .env. Borra el archivo y vuelve a ejecutar setup.sh."
    fi
done

# Validación de longitud mínima para MinIO
if [ ${#MINIO_ROOT_PASSWORD} -lt 8 ]; then
    log_error "MINIO_ROOT_PASSWORD debe tener al menos 8 caracteres. Borra .env y vuelve a ejecutar setup.sh."
fi
if [ ${#MINIO_ROOT_USER} -lt 3 ]; then
    log_error "MINIO_ROOT_USER debe tener al menos 3 caracteres. Borra .env y vuelve a ejecutar setup.sh."
fi

log_success "Contraseñas cargadas correctamente"
echo ""

# ============================================================
# 3. Verificar que el clúster está disponible
# ============================================================
if ! kubectl cluster-info &>/dev/null; then
    log_error "No se puede conectar al clúster. Arranca Minikube primero: minikube start"
fi

# ============================================================
# 4. Asegurar que los namespaces existen
# ============================================================
log_info "Verificando namespaces necesarios..."
for ns in storage wordpress monitoring; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
done
log_success "Namespaces verificados"
echo ""

# ============================================================
# 5. Inyectar Secret de MinIO
# ============================================================
log_info "Inyectando secret de MinIO..."

kubectl create secret generic minio-secret \
    --namespace storage \
    --from-literal=root-user="${MINIO_ROOT_USER}" \
    --from-literal=root-password="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - \
    || log_error "Error aplicando minio-secret en namespace 'storage'"
log_success "minio-secret (storage) aplicado"

kubectl create secret generic minio-secret \
    --namespace wordpress \
    --from-literal=access-key="${MINIO_ROOT_USER}" \
    --from-literal=secret-key="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - \
    || log_error "Error aplicando minio-secret en namespace 'wordpress'"
log_success "minio-secret (wordpress) aplicado"

# ============================================================
# 6. Inyectar Secret de Grafana
# ============================================================
log_info "Inyectando secret de Grafana..."

kubectl create secret generic grafana-secret \
    --namespace monitoring \
    --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - \
    || log_error "Error aplicando grafana-secret en namespace 'monitoring'"
log_success "grafana-secret (monitoring) aplicado"

# ============================================================
# 7. Actualizar .gitignore
# ============================================================
GITIGNORE="$SCRIPT_DIR/.gitignore"
GITIGNORE_ENTRIES=(
    ".env"
    "*.bak"
    "secrets/"
    "sealed-secrets-master-key-backup.yaml"
    "sealed-secrets-backup-*/"
)

ADDED=false
for entry in "${GITIGNORE_ENTRIES[@]}"; do
    if ! grep -qF "$entry" "$GITIGNORE" 2>/dev/null; then
        echo "$entry" >> "$GITIGNORE"
        ADDED=true
    fi
done
$ADDED && log_success ".gitignore actualizado" || log_success ".gitignore ya está al día"

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   ✅  Configuración completada${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  Secrets aplicados en el clúster:"
echo -e "    ${GREEN}✓${NC} minio-secret     (storage, wordpress)"
echo -e "    ${GREEN}✓${NC} grafana-secret   (monitoring)"
echo ""
echo -e "  Los secrets de MariaDB y Redis los gestiona:"
echo -e "    ${YELLOW}→${NC} scripts/03-deploy-core.sh  (via SealedSecrets)"
echo ""
echo -e "  El archivo ${YELLOW}.env${NC} y la carpeta ${YELLOW}secrets/${NC} están en .gitignore."
echo ""
echo -e "${BLUE}  Siguiente paso → despliega el proyecto:${NC}"
echo -e "  ${GREEN}./deploy.sh${NC}"
echo ""
