# RUNBOOK — WordPress HA en Kubernetes

**Proyecto:** KubeNet — WordPress HA en Minikube  
**Versión:** 1.2 (Actualizado tras sesión de fixes DNS/Grafana)  
**Entorno:** Minikube + Kubernetes v1.35

> ⚠️ **Nota de seguridad:** Este runbook no contiene credenciales en texto plano.  
> Todos los comandos leen las contraseñas directamente desde los Kubernetes Secrets del clúster.

---

## Cómo leer credenciales del clúster

Ejecuta este bloque antes de realizar operaciones manuales para cargar las contraseñas en tu sesión:

```bash
# MariaDB Root
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
echo "MariaDB Root: $MARIADB_ROOT_PASS"

# MariaDB User
MARIADB_USER_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-user-password}' | base64 -d)
echo "MariaDB User: $MARIADB_USER_PASS"

# Redis
REDIS_PASS=$(kubectl get secret redis-secret -n databases \
  -o jsonpath='{.data.redis-password}' | base64 -d)
echo "Redis: $REDIS_PASS"
```

---

## Índice

1. [Prometheus — Lockfile corrupto](#1-prometheus--lockfile-corrupto)
2. [Namespace atascado en Terminating](#2-namespace-atascado-en-terminating)
3. [Sealed Secrets inválidos](#3-sealed-secrets-inválidos)
4. [MariaDB — Replicación rota](#4-mariadb--replicación-rota)
5. [WordPress — Fallo de conexión externa (DNS)](#5-wordpress--fallo-de-conexión-externa-dns)
6. [Grafana — Login inválido (Desfase de DB)](#6-grafana--login-inválido-desfase-de-db)
7. [KEDA / Velero — Error ImagePullBackOff](#7-keda--velero--error-imagepullbackoff)
8. [Minikube Tunnel — Ingress Inaccesible](#8-minikube-tunnel--ingress-inaccesible)

---

## 1. Prometheus — Lockfile corrupto

**Síntoma:** El pod de Prometheus está en `CrashLoopBackOff` y los logs muestran `flock: resource temporarily unavailable`.

**Solución:** Borrar el archivo de bloqueo en el PVC.

```bash
kubectl exec -it -n monitoring prometheus-server-0 -- rm -f /data/queries.active
```

---

## 2. Namespace atascado en Terminating

**Síntoma:** El namespace no se borra tras varios minutos.

**Solución:** Eliminar los finalizers manualmente mediante la API.

```bash
kubectl get namespace <namespace> -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

---

## 3. Sealed Secrets inválidos

**Síntoma:** Los pods de bases de datos dan error de login tras un cambio de clave.

**Solución:** Borrar el Secret sellado y volver a generar el YAML usando `kubeseal` con la clave pública del clúster.

---

## 4. MariaDB — Replicación rota

**Síntoma:** `Slave_IO_Running: No` al ejecutar `SHOW SLAVE STATUS\G`.

**Solución:**

1. Obtener coordenadas del Master en `mariadb-0`.
2. Reiniciar el slave en `mariadb-1`:

```sql
STOP SLAVE;
CHANGE MASTER TO
  MASTER_PASSWORD='$MARIADB_REPL_PASS',
  MASTER_LOG_FILE='...',
  MASTER_LOG_POS=...;
START SLAVE;
```

---

## 5. WordPress — Fallo de conexión externa (DNS)

**Síntoma:** Error "An unexpected error occurred" en el panel de WordPress. `curl -I https://wordpress.org` falla con `error (6)`.

**Causa:** CoreDNS no resuelve nombres externos en entornos Minikube/Debian.

**Solución:**

1. Editar ConfigMap:
   ```bash
   kubectl edit configmap coredns -n kube-system
   ```
2. Cambiar `forward . /etc/resolv.conf` por `forward . 8.8.8.8 8.8.4.4`.
3. Reiniciar CoreDNS:
   ```bash
   kubectl rollout restart deployment coredns -n kube-system
   ```

---

## 6. Login inválido (Desfase de DB)

**Síntoma:** El login de cualquier recurso falla aunque el Secret sea correcto en Kubernetes.

**Causa:** La base de datos interna de Grafana no se actualiza automáticamente si se cambia el Secret tras el primer despliegue.

**Solución:** Ejecutar el script de arranque general:

```bash
./start_all.sh
```

> Si el problema persiste, como solución alternativa puedes resetear la contraseña directamente vía CLI:
> ```bash
> kubectl exec -n monitoring -it deployment/grafana -- \
>   grafana cli admin reset-admin-password "TuNuevaPassword123"
> ```

---

## 7. KEDA / Velero — Error ImagePullBackOff

**Síntoma:** Pods atascados intentando descargar imágenes (especialmente `minio/mc`).

**Solución:**

1. Actualizar tags en los manifiestos (evitar versiones de 2024 deprecadas).
2. Forzar carga manual:
   ```bash
   minikube image load minio/mc:latest
   ```

---

## 8. Minikube Tunnel — Ingress Inaccesible

**Síntoma:** Dominios `.local` no cargan. El Ingress no muestra IP.

**Solución:**

1. ```bash
   sudo pkill -f minikube tunnel
   ```
2. ```bash
   sudo minikube tunnel --cleanup
   ```
3. Verificar que `/etc/hosts` apunta a la IP correcta de Minikube.

---

## Referencia rápida de errores

| Problema             | Síntoma clave             | Runbook |
|----------------------|---------------------------|---------|
| WP sin internet      | Could not resolve host    | §5      |
| Grafana bloqueado    | Invalid credentials       | §6      |
| Pods no arrancan     | ImagePullBackOff          | §7      |
| Ingress no responde  | Timeout / 404             | §8      |
