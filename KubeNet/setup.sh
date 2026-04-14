#!/bin/bash
# ============================================================
# setup.sh — Configuración inicial de contraseñas
#
# Si no existe .env, lo genera de forma interactiva preguntando
# cada contraseña al usuario.
#
# Propaga las contraseñas a los YAMLs del proyecto y genera el
# .gitignore para que no se suban al repositorio.
#
# BUG CORREGIDO: el script original guardaba el valor original
# de cada YAML en un .bak y luego siempre leía el patrón a
# reemplazar desde el .bak. En la segunda ejecución (p.ej. para
# cambiar una contraseña), el .bak ya existía con los valores
# del repo, pero el YAML ya tenía la contraseña de la primera
# ejecución — el sed no encontraba el patrón y no hacía nada.
#
# Solución: leer siempre el patrón actual directamente del YAML
# que se va a modificar, no del .bak. El .bak sigue existiendo
# como copia de seguridad del original del repo, pero ya no se
# usa como fuente del patrón de búsqueda.
#
# USO:
#   ./setup.sh         # genera .env si no existe, luego aplica cambios
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
    local value=""
    while [ -z "$value" ]; do
      read -rp "  $prompt: " value
      [ -z "$value" ] && echo -e "  ${RED}No puede estar vacío.${NC}"
    done
    echo "$var_name=$value" >> "$ENV_FILE"
    export "$var_name=$value"
  }

  read_password() {
    local var_name="$1"
    local prompt="$2"
    local value=""
    while [ -z "$value" ]; do
      read -rsp "  $prompt: " value
      echo ""
      [ -z "$value" ] && echo -e "  ${RED}No puede estar vacío.${NC}"
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
  read_value    "MINIO_ROOT_USER"        "Usuario root de MinIO (ej: minioadmin)"
  read_password "MINIO_ROOT_PASSWORD"    "Contraseña root de MinIO"
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

log_success "Contraseñas cargadas correctamente"
echo ""

# ============================================================
# 3. Parchear redis.yaml
#
# BUG CORREGIDO: leer el patrón actual DESDE EL YAML,
# no desde el .bak (que contiene los valores originales del repo).
# ============================================================
REDIS_YAML="$SCRIPT_DIR/k8s/data/redis.yaml"
log_info "Parcheando redis.yaml..."

[ ! -f "${REDIS_YAML}.bak" ] && cp "$REDIS_YAML" "${REDIS_YAML}.bak"

# Leer valor actual directamente del YAML (no del .bak)
CURRENT_REDIS_PASS=$(grep -m1 'requirepass ' "$REDIS_YAML" | awk '{print $2}')

if [ -n "$CURRENT_REDIS_PASS" ] && [ "$CURRENT_REDIS_PASS" != "$REDIS_PASSWORD" ]; then
  sed -i "s|requirepass ${CURRENT_REDIS_PASS}|requirepass ${REDIS_PASSWORD}|g" "$REDIS_YAML"
  sed -i "s|masterauth ${CURRENT_REDIS_PASS}|masterauth ${REDIS_PASSWORD}|g" "$REDIS_YAML"
  sed -i "s|sentinel auth-pass mymaster ${CURRENT_REDIS_PASS}|sentinel auth-pass mymaster ${REDIS_PASSWORD}|g" "$REDIS_YAML"
  sed -i "s|redis-cli -a '${CURRENT_REDIS_PASS}'|redis-cli -a '${REDIS_PASSWORD}'|g" "$REDIS_YAML"
  log_success "redis.yaml actualizado"
elif [ "$CURRENT_REDIS_PASS" = "$REDIS_PASSWORD" ]; then
  log_success "redis.yaml ya tiene la contraseña correcta — sin cambios"
else
  log_warn "No se encontró la contraseña en redis.yaml — verifica manualmente"
fi

# ============================================================
# 4. Parchear minio.yaml
# ============================================================
MINIO_YAML="$SCRIPT_DIR/k8s/storage/minio.yaml"
log_info "Parcheando minio.yaml..."

[ ! -f "${MINIO_YAML}.bak" ] && cp "$MINIO_YAML" "${MINIO_YAML}.bak"

# Leer valores actuales del YAML (no del .bak)
CURRENT_MINIO_USER=$(grep -m1 'root-user:'     "$MINIO_YAML" | awk '{print $2}')
CURRENT_MINIO_PASS=$(grep -m1 'root-password:' "$MINIO_YAML" | awk '{print $2}')
CURRENT_ACCESS=$(grep    -m1 'access-key:'     "$MINIO_YAML" | awk '{print $2}')
CURRENT_SECRET=$(grep    -m1 'secret-key:'     "$MINIO_YAML" | awk '{print $2}')

[ -n "$CURRENT_MINIO_USER" ] && sed -i "s|root-user: ${CURRENT_MINIO_USER}|root-user: ${MINIO_ROOT_USER}|g"             "$MINIO_YAML"
[ -n "$CURRENT_MINIO_PASS" ] && sed -i "s|root-password: ${CURRENT_MINIO_PASS}|root-password: ${MINIO_ROOT_PASSWORD}|g" "$MINIO_YAML"
[ -n "$CURRENT_ACCESS" ]     && sed -i "s|access-key: ${CURRENT_ACCESS}|access-key: ${MINIO_ROOT_USER}|g"               "$MINIO_YAML"
[ -n "$CURRENT_SECRET" ]     && sed -i "s|secret-key: ${CURRENT_SECRET}|secret-key: ${MINIO_ROOT_PASSWORD}|g"           "$MINIO_YAML"

log_success "minio.yaml actualizado"

# ============================================================
# 5. Parchear grafana.yaml
# ============================================================
GRAFANA_YAML="$SCRIPT_DIR/k8s/observability/grafana.yaml"
log_info "Parcheando grafana.yaml..."

[ ! -f "${GRAFANA_YAML}.bak" ] && cp "$GRAFANA_YAML" "${GRAFANA_YAML}.bak"

GRAFANA_USER_B64=$(echo -n "$GRAFANA_ADMIN_USER"     | base64)
GRAFANA_PASS_B64=$(echo -n "$GRAFANA_ADMIN_PASSWORD" | base64)

# Leer valores actuales del YAML (no del .bak)
CURRENT_USER_B64=$(grep 'admin-user:'     "$GRAFANA_YAML" | awk '{print $2}')
CURRENT_PASS_B64=$(grep 'admin-password:' "$GRAFANA_YAML" | awk '{print $2}')

[ -n "$CURRENT_USER_B64" ] && sed -i "s|admin-user: ${CURRENT_USER_B64}|admin-user: ${GRAFANA_USER_B64}|g"         "$GRAFANA_YAML"
[ -n "$CURRENT_PASS_B64" ] && sed -i "s|admin-password: ${CURRENT_PASS_B64}|admin-password: ${GRAFANA_PASS_B64}|g" "$GRAFANA_YAML"

log_success "grafana.yaml actualizado"

# ============================================================
# 6. Añadir .gitignore si no existe o completarlo
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
echo -e "  Archivos actualizados:"
echo -e "    ${GREEN}✓${NC} k8s/data/redis.yaml"
echo -e "    ${GREEN}✓${NC} k8s/storage/minio.yaml"
echo -e "    ${GREEN}✓${NC} k8s/observability/grafana.yaml"
echo -e "    ${GREEN}✓${NC} .gitignore"
echo ""
echo -e "  Los originales del repo tienen copia en ${YELLOW}*.bak${NC}"
echo -e "  El archivo ${YELLOW}.env${NC} y la carpeta ${YELLOW}secrets/${NC} están en .gitignore."
echo ""
echo -e "${BLUE}  Siguiente paso → despliega el proyecto:${NC}"
echo -e "  ${GREEN}minikube start --cpus=4 --memory=8192${NC}"
echo -e "  ${GREEN}./deploy.sh${NC}"
echo ""
