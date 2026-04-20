# 🚀 KubeNet — WordPress HA en Kubernetes

> Infraestructura cloud-native completa sobre Minikube: alta disponibilidad, escalado por tráfico real, observabilidad end-to-end y seguridad en profundidad. Entorno de producción simulado, no una demo básica.

---

## 📑 Índice

1. [Descripción](#-descripción)
2. [Objetivo del proyecto](#-objetivo-del-proyecto)
3. [Despliegue rápido](#-despliegue-rápido)
4. [Stack tecnológico](#-stack-tecnológico)
5. [Arquitectura](#-arquitectura)
6. [Alta disponibilidad](#-alta-disponibilidad)
7. [Escalado automático (KEDA)](#-escalado-automático-keda)
8. [Seguridad](#-seguridad)
9. [Observabilidad](#-observabilidad)
10. [Backup y recuperación](#-backup-y-recuperación)
11. [CI Pipeline](#-ci-pipeline)
12. [Accesos y testing](#-accesos-y-testing)
13. [Estructura del proyecto](#-estructura-del-proyecto)
14. [Decisiones de diseño](#-decisiones-de-diseño)
15. [Limitaciones conocidas](#-limitaciones-conocidas)
16. [Próximas mejoras](#-próximas-mejoras)
17. [Valor del proyecto](#-valor-del-proyecto)
18. [Comandos útiles](#-comandos-útiles)
19. [Licencia](#-licencia)

---

## 📋 Descripción

KubeNet es un despliegue de WordPress en alta disponibilidad sobre Kubernetes (Minikube) diseñado como **entorno de producción simulado**, con las mismas capas que encontrarías en una arquitectura cloud-native real.

Lo que lo diferencia de una demo estándar: escala por tráfico real (no solo CPU), implementa observabilidad completa con métricas + logs + trazas, gestiona secretos cifrados versionables, y automatiza backups con objetivos RPO/RTO definidos. Todo el despliegue es reproducible desde cero con tres comandos.

---

## 🎯 Objetivo del proyecto

El objetivo no es levantar WordPress. Es demostrar:

- **IaC real**: toda la infraestructura declarada en YAML versionado, sin pasos manuales
- **Automatización completa**: un solo script despliega el clúster entero de forma idempotente
- **Reproducibilidad**: cualquier persona puede clonar el repo y tener el entorno exacto en minutos
- **Mínima intervención manual**: las contraseñas se generan interactivamente una sola vez y nunca se versionan

---

## ⚡ Despliegue rápido

```bash
# 1. Clonar el repositorio
git clone <repo>
cd KubeNet

# 2. Instalar dependencias (Docker, kubectl, Minikube, Helm)
chmod +x install.sh && ./install.sh
# ⚠️ Si Docker se acaba de instalar, cierra sesión y vuelve a entrar antes de continuar

# 3. Arrancar Minikube
minikube start --cpus=4 --memory=8192

# 4. Configurar contraseñas (se generan interactivamente, nunca se guardan en el repo)
chmod +x setup.sh && ./setup.sh

# 5. Desplegar
chmod +x deploy.sh && ./deploy.sh

# 6. Exponer servicios — ejecutar en otra terminal y dejar corriendo
minikube tunnel
```

Acceso tras el despliegue: **https://wp-k8s.local**

> ✔ `deploy.sh` es **idempotente**: puede ejecutarse múltiples veces sin romper el estado del clúster.
> El navegador mostrará un aviso de certificado self-signed — acepta la excepción.

**Requisitos mínimos de la máquina:**

| Recurso | Mínimo |
|---|---|
| CPU | 4 cores |
| RAM | 8 GB |
| Disco | 40 GB |

---

## 🧠 Stack tecnológico

| Capa | Tecnología |
|---|---|
| Orquestación | Kubernetes (Minikube) |
| Aplicación | WordPress |
| Base de datos | MariaDB (Primary + Replica) |
| Caché | Redis + Sentinel |
| Autoscaling | KEDA |
| Almacenamiento | MinIO (S3 compatible) |
| TLS | cert-manager |
| Backup | Velero |
| Métricas | Prometheus |
| Visualización | Grafana |
| Logs | Loki + Promtail |
| Trazas | Jaeger + OpenTelemetry |
| Secrets | Sealed Secrets (kubeseal) |
| CI | kubeconform · kube-score · detect-secrets |

---

## 🏗️ Arquitectura

### Flujo de petición

```
Browser
  │
  ▼
Ingress NGINX (TLS terminado)
  │
  ▼
Service WordPress
  │
  ┌──────────────┴──────────────┐
  ▼                             ▼
Redis (caché de objetos)   MariaDB Primary (R/W)
                                │
                                ▼
                          MariaDB Replica (R + failover)
```

### Namespaces

| Namespace | Propósito |
|---|---|
| `wordpress` | Aplicación |
| `databases` | MariaDB + Redis |
| `monitoring` | Observabilidad |
| `security` | cert-manager + Sealed Secrets |
| `storage` | MinIO + backups |
| `velero` | Snapshots de clúster |

### Componentes y HA

| Componente | Tipo | Alta Disponibilidad |
|---|---|---|
| WordPress | Deployment | Sí (mín. 2 pods) |
| MariaDB | StatefulSet | Primary + Replica |
| Redis | StatefulSet | Sentinel failover |
| MinIO | Deployment | Persistente |
| Prometheus Stack | Stateful | Observabilidad |

---

## 🔁 Alta disponibilidad

**WordPress**
- Mínimo 2 réplicas activas + `PodDisruptionBudget`
- `readinessProbe` y `livenessProbe` en todos los pods

**MariaDB**
- `mariadb-0` → Primary (R/W), `mariadb-1` → Replica (R + failover)
- Replicación automática gestionada por Job de inicialización

**Redis + Sentinel**
- 1 master + 2 réplicas
- 3 instancias de Sentinel para quórum y failover automático

---

## 📈 Escalado automático (KEDA)

El autoscaling está gestionado por **KEDA** (Kubernetes Event-Driven Autoscaling) en lugar de HPA clásico.

| Parámetro | Valor |
|---|---|
| Mínimo de pods | 2 |
| Máximo de pods | 10 |
| Trigger principal | Prometheus (req/s) |
| Trigger fallback | CPU |

**Por qué KEDA y no HPA:**
- Escala de forma **proactiva** ante picos de tráfico, antes de que ocurra la saturación
- Usa métricas reales de tráfico (req/s desde Prometheus), no solo CPU
- Soporta múltiples triggers y métricas externas

---

## 🔐 Seguridad

- **NetworkPolicies**: modelo default-deny en todos los namespaces; solo tráfico explícitamente declarado permitido
- **Sealed Secrets**: secretos cifrados y versionables en el repo; solo descifrables dentro del clúster con la clave privada del controlador
- **TLS (cert-manager)**: CA interna gestionada, certificados auto-renovables, HTTPS forzado en todos los endpoints; `FORCE_SSL_ADMIN` y `FORCE_SSL_LOGIN` activos en WordPress
- **Pod Security Standards**: perfil `baseline` en todos los namespaces; `privileged` únicamente en Velero (requerido por drivers de snapshot)

> ⚠️ No se almacenan credenciales reales ni en texto plano en el repositorio.

---

## 📊 Observabilidad

| Herramienta | Propósito |
|---|---|
| Prometheus | Recolección de métricas |
| Grafana | Dashboards y alertas |
| Loki + Promtail | Agregación de logs |
| Jaeger | Trazas distribuidas |
| OpenTelemetry | Instrumentación y telemetría |

**SLOs definidos:**

| Indicador | Objetivo |
|---|---|
| Disponibilidad | ≥ 99.5% |
| Latencia p95 | ≤ 2s |

El dashboard personalizado de Grafana (`Kubernetes_Dashboard.json`) está incluido en el repo para importación directa.

---

## 💾 Backup y recuperación

| Tipo | Frecuencia |
|---|---|
| DB dump (MariaDB) | Diario |
| Uploads (wp-content) | Diario |
| Snapshots de clúster (Velero) | Diario |

| Indicador | Valor |
|---|---|
| RPO (Recovery Point Objective) | 24h |
| RTO (Recovery Time Objective) | ~15 min |

---

## 🔄 CI Pipeline

Validación automática en cada push al repositorio:

| Herramienta | Qué valida |
|---|---|
| `kubeconform` | Validación de esquemas de manifiestos YAML |
| `kube-score` | Análisis de buenas prácticas (probes, limits, etc.) |
| `detect-secrets` | Detección de credenciales expuestas |
| Resource validation | Comprobación de limits/requests en todos los pods |

El pipeline ejecuta las validaciones contra un clúster Kind efímero, garantizando que los manifiestos son aplicables antes de cualquier merge.

---

## 🌐 Accesos y testing

| Servicio | URL |
|---|---|
| WordPress | https://wp-k8s.local |
| Grafana | https://grafana.monitoring.local |
| Prometheus | https://prometheus.monitoring.local |
| MinIO | http://minio.storage.local |

> Requiere `minikube tunnel` activo y las entradas correspondientes en `/etc/hosts`.

**Verificación rápida post-despliegue:**

```bash
# Comprobar que todos los pods están Running
kubectl get pods -A

# Verificar que el ScaledObject de KEDA está activo
kubectl get scaledobject -n wordpress

# Comprobar certificados TLS
kubectl get certificates -A
```

---

## 📁 Estructura del proyecto

```
.
├── install.sh                           # Instalación de dependencias
├── deploy.sh                            # Despliegue idempotente completo
├── setup.sh                             # Configuración inicial de contraseñas
├── runbook.md                           # Procedimientos operativos
│
└── k8s/
    ├── app/
    │   ├── wordpress.yaml               # Deployment + Service de WordPress
    │   └── keda-wordpress.yaml          # ScaledObject KEDA (min:2 max:10)
    │
    ├── core/
    │   ├── namespace.yaml               # Namespaces del proyecto
    │   ├── configmap.yaml               # ConfigMaps
    │   ├── network-policy.yaml          # NetworkPolicies (default-deny)
    │   ├── pdb.yaml                     # PodDisruptionBudget
    │   └── resource-quota.yaml          # ResourceQuota y LimitRange
    │
    ├── data/
    │   ├── mariadb.yaml                 # MariaDB HA (primary + replica)
    │   ├── mariadb-replication-job.yaml # Job de configuración de replicación
    │   └── redis.yaml                   # Redis HA + Sentinel
    │
    ├── edge/
    │   ├── cert-manager.yaml            # ClusterIssuers + Certificados TLS
    │   └── ingress.yaml                 # Ingress NGINX con TLS
    │
    ├── observability/
    │   ├── prometheus.yaml              # Prometheus + Alertmanager
    │   ├── grafana.yaml                 # Grafana con datasources integrados
    │   ├── loki.yaml                    # Loki + Promtail
    │   └── tracing.yaml                 # Jaeger + OTel Collector
    │
    └── storage/
        ├── pvc.yaml                     # PersistentVolumeClaims
        ├── minio.yaml                   # MinIO S3 compatible
        ├── backup.yaml                  # CronJobs de backup
        └── velero.yaml                  # Velero + NetworkPolicy
```

---

## ⚖️ Decisiones de diseño

| Decisión | Motivo |
|---|---|
| YAML plano (sin Helm) | Control total sobre cada manifiesto; sin abstracciones que oculten comportamiento |
| KEDA en lugar de HPA | Escalado por tráfico real (req/s), no solo CPU; proactivo en vez de reactivo |
| MinIO en lugar de S3 real | Almacenamiento S3 local sin dependencia cloud; entorno 100% reproducible |
| Sealed Secrets | Secretos cifrados versionables sin necesidad de gestión cloud externa |
| Jaeger en modo simple | Menor complejidad operativa para entorno local, suficiente para tracing |
| Minikube | Entorno completamente reproducible en cualquier máquina local |
| setup.sh interactivo | Las contraseñas nunca se versionan; se generan en el momento del despliegue |

---

## 🚧 Limitaciones conocidas

- **Entorno local**: sin LoadBalancer externo ni DNS público; requiere `minikube tunnel` y `/etc/hosts`
- **Sin multi-nodo**: Minikube corre en un único nodo; la HA es lógica, no física
- **Algunas imágenes no son rootless**: limitación de las imágenes upstream, no del despliegue
- **Sin GitOps**: ArgoCD/Flux están fuera del alcance actual del proyecto

---

## 📌 Próximas mejoras

- [ ] Migración de manifiestos a Helm / Kustomize
- [ ] GitOps con ArgoCD
- [ ] External Secrets Operator
- [ ] Clúster multi-nodo real
- [ ] Pipeline CI con despliegue automático en cada merge

---

## 🧠 Valor del proyecto

Este proyecto demuestra capacidad para:

- Diseñar arquitecturas cloud-native completas con criterio, no solo seguir tutoriales
- Operar Kubernetes de forma realista: probes, PDBs, NetworkPolicies, resource quotas
- Implementar observabilidad real: métricas + logs + trazas + alertas + SLOs
- Gestionar secretos de forma segura sin comprometer la reproducibilidad del repo
- Tomar decisiones técnicas razonadas y documentarlas (KEDA vs HPA, MinIO vs S3, etc.)
- Automatizar el ciclo completo de despliegue con scripts idempotentes

---

## 🧰 Comandos útiles

```bash
# Estado general del clúster
kubectl get pods -A

# Logs de WordPress en tiempo real
kubectl logs -n wordpress -l app=wordpress -f

# Ver ScaledObject de KEDA
kubectl get scaledobject -n wordpress

# Listar backups de Velero
velero backup get

# Verificar certificados TLS
kubectl get certificates -A

# Estado de la replicación MariaDB
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Running|Behind'

# Limpiar el entorno completo
./deploy.sh --cleanup
```


