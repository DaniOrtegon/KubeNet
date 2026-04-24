#!/bin/bash
# ============================================================
# setup-slack.sh — Configura Alertmanager con Slack webhook
# ============================================================
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}   ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}   ⚠️  $*${NC}"; }
fail() { echo -e "${RED}   ❌ $*${NC}"; exit 1; }
info() { echo -e "${CYAN}   ℹ️  $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMETHEUS_YAML="$SCRIPT_DIR/../k8s/observability/prometheus.yaml"

echo ""
echo "=================================================="
echo "   🔔 KubeNet — Configuración de Alertmanager + Slack"
echo "=================================================="
echo ""

# Verificar que el archivo existe
[ -f "$PROMETHEUS_YAML" ] || fail "No se encontró $PROMETHEUS_YAML. Ejecuta este script desde la raíz del proyecto."

# Pedir la URL del webhook
read -rp "   Introduce la Slack Webhook URL: " WEBHOOK_URL

# Validar formato
[[ "$WEBHOOK_URL" =~ ^https://hooks.slack.com/services/ ]] || fail "La URL no tiene el formato correcto. Debe empezar por https://hooks.slack.com/services/"

info "Actualizando $PROMETHEUS_YAML..."

python3 - << PYEOF
import sys

with open('$PROMETHEUS_YAML', 'r') as f:
    content = f.read()

webhook = '$WEBHOOK_URL'

# Descomentar y actualizar critical-receiver
old1 = None
for old in [
    content[content.find('# slack_configs'):content.find('# slack_configs') + 500]
]:
    pass

# Reemplazar todas las URLs placeholder
content = content.replace("https://hooks.slack.com/services/XXX/YYY/ZZZ", webhook)

# Descomentar bloques slack_configs (critical y warning)
import re

def uncomment_slack_block(text):
    # Descomenta líneas que empiecen con espacios + '# slack_configs' o '#   -' o '# \t'
    lines = text.split('\n')
    result = []
    in_slack_block = False
    for line in lines:
        stripped = line.lstrip()
        # Detectar inicio del bloque comentado
        if '# slack_configs:' in line:
            in_slack_block = True
        if in_slack_block:
            # Quitar el comentario
            line = re.sub(r'^(\s*)#\s?', r'\1', line)
            if line.strip() == '' or (not line.strip().startswith('-') and not line.strip().startswith('api_url') and not line.strip().startswith('channel') and not line.strip().startswith('icon_emoji') and not line.strip().startswith('send_resolved') and not line.strip().startswith('title') and not line.strip().startswith('text') and not line.strip().startswith('{{') and not line.strip().startswith('*') and 'slack_configs' not in line):
                in_slack_block = False
        result.append(line)
    return '\n'.join(result)

content = uncomment_slack_block(content)

with open('$PROMETHEUS_YAML', 'w') as f:
    f.write(content)

print("OK")
PYEOF

ok "prometheus.yaml actualizado"

# Aplicar el ConfigMap
info "Aplicando configuración en Kubernetes..."
kubectl apply -f "$PROMETHEUS_YAML" || fail "Error al aplicar el yaml"
ok "ConfigMap aplicado"

# Reiniciar Alertmanager para que lea la nueva config
info "Reiniciando Alertmanager..."
kubectl rollout restart deployment/alertmanager -n monitoring || fail "Error al reiniciar Alertmanager"
kubectl rollout status deployment/alertmanager -n monitoring --timeout=60s
ok "Alertmanager reiniciado"

# Test del webhook
echo ""
info "Enviando mensaje de prueba a Slack..."
curl -s -X POST -H 'Content-type: application/json' \
    --data '{"text":"✅ KubeNet — Alertmanager conectado correctamente a Slack"}' \
    "$WEBHOOK_URL" && echo ""
ok "Mensaje de prueba enviado a #alertas-k8s"

echo ""
echo "=================================================="
echo -e "${GREEN}  🎉 Alertmanager configurado con Slack${NC}"
echo "=================================================="
echo ""
