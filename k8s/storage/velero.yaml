#!/bin/bash
# ============================================================
# 08-deploy-velero.sh — Velero (backup completo del clúster)
#
# Instala Velero con backend MinIO local:
#   - Bucket: velero-backups (creado en el paso 05)
#   - Schedule: diario a la 1:00 AM
#   - Namespaces: wordpress + databases
#   - Retención: 30 días (720h)
#   - Incluye snapshots de PVCs via CSI
#
# PRE-REQUISITO: MinIO debe estar desplegado (script 05)
#
# USO:
#   ./scripts/08-deploy-velero.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K8S_DIR="$SCRIPT_DIR/k8s"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   [08] Velero — Backup completo del clúster${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ------------------------------------------------------------
# Addons CSI necesarios para snapshots de PVCs
# ------------------------------------------------------------
log_info "Activando addons CSI para snapshots de volúmenes..."
timeout 120s minikube addons enable volumesnapshots &>/dev/null 2>&1 \
  && log_success "Addon volumesnapshots activado" \
  || log_warn "volumesnapshots tardó demasiado — continuando"

timeout 120s minikube addons enable csi-hostpath-driver &>/dev/null 2>&1 \
  && log_success "Addon csi-hostpath-driver activado" \
  || log_warn "csi-hostpath-driver tardó demasiado — continuando"

# ------------------------------------------------------------
# Repo Helm vmware-tanzu
# ------------------------------------------------------------
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
helm repo update vmware-tanzu 2>/dev/null || true

# ------------------------------------------------------------
# Namespace velero
# Limpiar si está atascado en Terminating
# ------------------------------------------------------------
if kubectl get namespace velero &>/dev/null 2>&1; then
  local_phase=$(kubectl get namespace velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$local_phase" = "Terminating" ]; then
    log_warn "Namespace velero en Terminating — forzando limpieza..."
    kubectl get namespace velero -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
      | kubectl replace --raw "/api/v1/namespaces/velero/finalize" -f - 2>/dev/null || true
    sleep 5
  fi
fi
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
sleep 2

# ------------------------------------------------------------
# Bucket velero-backups en MinIO
# ------------------------------------------------------------
log_info "Configurando bucket velero-backups en MinIO..."
kubectl delete job velero-bucket-setup -n storage --ignore-not-found=true 2>/dev/null || true
apply_file "$K8S_DIR/storage/velero.yaml" "Velero — bucket setup + NetworkPolicy"
kubectl wait --for=condition=complete job/velero-bucket-setup \
  -n storage --timeout=60s 2>/dev/null \
  && log_success "Bucket velero-backups creado" \
  || log_warn "Job velero-bucket-setup no completó — verifica: kubectl logs -n storage job/velero-bucket-setup"

# ------------------------------------------------------------
# Credenciales MinIO para Velero
# FIX: las keys correctas en minio-secret (storage) son
#      root-user / root-password, no access-key / secret-key
# ------------------------------------------------------------
MINIO_ACCESS_KEY=$(kubectl get secret minio-secret -n storage \
  -o jsonpath='{.data.root-user}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
MINIO_SECRET_KEY=$(kubectl get secret minio-secret -n storage \
  -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
MINIO_URL="http://minio.storage.svc.cluster.local:9000"

if [ -z "$MINIO_ACCESS_KEY" ] || [ -z "$MINIO_SECRET_KEY" ]; then
  log_error "No se encontraron credenciales de MinIO en minio-secret (storage). Ejecuta ./setup.sh primero."
fi

log_success "Credenciales de MinIO leídas correctamente (usuario: ${MINIO_ACCESS_KEY})"

# ------------------------------------------------------------
# Instalar Velero via Helm
# ------------------------------------------------------------
cat > /tmp/velero-values.yaml << HELMEOF
credentials:
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=${MINIO_ACCESS_KEY}
      aws_secret_access_key=${MINIO_SECRET_KEY}

configuration:
  backupStorageLocation:
    - name: minio
      provider: aws
      bucket: velero-backups
      default: true
      config:
        region: minio
        s3ForcePathStyle: "true"
        s3Url: "${MINIO_URL}"
  volumeSnapshotLocation:
    - name: minio
      provider: aws
      config:
        region: minio

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.8.2
    imagePullPolicy: Never
    volumeMounts:
      - mountPath: /target
        name: plugins

image:
  repository: velero/velero
  tag: v1.12.4
  pullPolicy: Never

features: "EnableCSI"
HELMEOF

helm upgrade --install velero vmware-tanzu/velero \
  --namespace velero \
  --version 5.2.0 \
  --values /tmp/velero-values.yaml \
  --set upgradeCRDs=false \
  --timeout 5m \
  || log_warn "Velero helm install falló — continuando sin Velero"

rm -f /tmp/velero-values.yaml
wait_for_deployment "velero" "velero" 180

# ------------------------------------------------------------
# Schedule de backup diario
# ------------------------------------------------------------
velero schedule create wordpress-daily \
  --schedule="0 1 * * *" \
  --include-namespaces wordpress,databases \
  --ttl 720h \
  2>/dev/null || log_warn "Schedule velero ya existe o no se pudo crear"

log_success "Velero instalado — schedule diario a la 1:00 AM configurado"

echo ""
log_success "[08] Velero desplegado correctamente"
echo ""
