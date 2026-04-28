# RUNBOOK — KubeNet WordPress HA on Kubernetes

**Project:** KubeNet — WordPress HA on Minikube  
**Version:** 1.3  
**Environment:** Minikube + Kubernetes v1.35

> ⚠️ **Security note:** This runbook contains no plaintext credentials.
> All commands read passwords directly from the cluster's Kubernetes Secrets.

---

## Reading cluster credentials

Run this block before any manual operation to load passwords into your session:

```bash
# MariaDB Root
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)

# MariaDB User
MARIADB_USER_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-user-password}' | base64 -d)

# Redis
REDIS_PASS=$(kubectl get secret redis-secret -n databases \
  -o jsonpath='{.data.redis-password}' | base64 -d)
```

---

## Index

1. [Prometheus — Corrupted lockfile](#1-prometheus--corrupted-lockfile)
2. [Namespace stuck in Terminating](#2-namespace-stuck-in-terminating)
3. [Sealed Secrets invalid after key change](#3-sealed-secrets-invalid-after-key-change)
4. [MariaDB — Broken replication](#4-mariadb--broken-replication)
5. [WordPress — External connection failure (DNS)](#5-wordpress--external-connection-failure-dns)
6. [Grafana — Invalid login (DB drift)](#6-grafana--invalid-login-db-drift)
7. [ImagePullBackOff on Minikube](#7-imagepullbackoff-on-minikube)
8. [Minikube Tunnel — Ingress unreachable](#8-minikube-tunnel--ingress-unreachable)
9. [Redis — CrashLoopBackOff (race condition with Sealed Secrets)](#9-redis--crashloopbackoff-race-condition-with-sealed-secrets)
10. [KEDA — New pods stuck in Pending](#10-keda--new-pods-stuck-in-pending)

---

## Quick error reference

| Problem | Key symptom | Section |
|---|---|---|
| WP no internet | Could not resolve host | §5 |
| Grafana locked | Invalid credentials | §6 |
| Pods won't start | ImagePullBackOff | §7 |
| Ingress not responding | Timeout / 404 | §8 |
| Redis won't start | CrashLoopBackOff on boot | §9 |
| KEDA doesn't scale | New pods stay Pending | §10 |
| Namespace won't delete | Stuck in Terminating | §2 |
| Replication broken | Slave_IO_Running: No | §4 |

---

## 1. Prometheus — Corrupted lockfile

**Symptom:** Prometheus pod is in `CrashLoopBackOff` and logs show `flock: resource temporarily unavailable`.

**Cause:** The lock file was not cleaned up after an unexpected shutdown.

**Fix:**
```bash
kubectl exec -it -n monitoring prometheus-server-0 -- rm -f /data/queries.active
```

---

## 2. Namespace stuck in Terminating

**Symptom:** Namespace does not delete after several minutes.

**Cause:** Resources from the `metrics.k8s.io` API group leave finalizers that block the deletion cycle indefinitely.

**Fix:** Remove finalizers manually via the API.
```bash
kubectl get namespace <namespace> -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

> This fix is implemented as the `delete_namespace_safe` function in `lib.sh`.

---

## 3. Sealed Secrets invalid after key change

**Symptom:** Database pods show login errors after a cluster rebuild or key rotation.

**Cause:** Sealed Secrets are encrypted with the cluster's private key. If the cluster is recreated, the old sealed secrets cannot be decrypted.

**Fix:**
1. Delete the existing sealed secret.
2. Re-encrypt using `kubeseal` with the new cluster's public key:
```bash
kubeseal --fetch-cert > pub-cert.pem
kubeseal --cert pub-cert.pem -f secret.yaml -w sealed-secret.yaml
kubectl apply -f sealed-secret.yaml
```

---

## 4. MariaDB — Broken replication

**Symptom:** `Slave_IO_Running: No` when running `SHOW SLAVE STATUS\G`.

**Fix:**

1. Get the current binlog coordinates from the primary (`mariadb-0`):
```bash
kubectl exec -n databases mariadb-0 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" \
  -e 'SHOW MASTER STATUS\G' 2>/dev/null
```

2. Reconnect the replica (`mariadb-1`) using those coordinates:
```bash
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" 2>/dev/null << EOF
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='mariadb-0.mariadb-headless.databases.svc.cluster.local',
  MASTER_USER='replicator',
  MASTER_PASSWORD='$MARIADB_ROOT_PASS',
  MASTER_LOG_FILE='<file>',
  MASTER_LOG_POS=<pos>;
START SLAVE;
EOF
```

3. Verify:
```bash
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" \
  -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Running|Behind'
```

Expected output: `Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`, `Seconds_Behind_Master: 0`

---

## 5. WordPress — External connection failure (DNS)

**Symptom:** "An unexpected error occurred" in the WordPress dashboard. `curl -I https://wordpress.org` fails with `error (6)`.

**Cause:** After reboots without `minikube stop`, the virtual gateway `192.168.49.1` stops forwarding DNS. CoreDNS inherits the broken resolver and all pods fail to resolve external domains.

**Fix:**

1. Edit the CoreDNS ConfigMap:
```bash
kubectl edit configmap coredns -n kube-system
```

2. Replace `forward . /etc/resolv.conf` with:
```
forward . 8.8.8.8 8.8.4.4
```

3. Restart CoreDNS:
```bash
kubectl rollout restart deployment coredns -n kube-system
```

> `start_all.sh` applies this fix automatically on every cluster startup.

---

## 6. Grafana — Invalid login (DB drift)

**Symptom:** Login fails even though the Kubernetes Secret is correct.

**Cause:** Grafana persists the admin user in an internal SQLite database. If the Kubernetes Secret changes after the first deployment, the internal DB is not automatically updated.

**Fix:** Run the startup script, which resets the password automatically:
```bash
./start_all.sh
```

If the problem persists, reset the password directly via CLI:
```bash
kubectl exec -n monitoring -it deployment/grafana -- \
  grafana cli admin reset-admin-password "$(kubectl get secret grafana-secret \
  -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)"
```

---

## 7. ImagePullBackOff on Minikube

**Symptom:** Pods stuck trying to pull images (especially `minio/mc`).

**Cause:** Minikube uses a separate Docker daemon from the host. With `pullPolicy: Always`, Kubernetes tries to pull local images from a non-existent remote registry. Also triggered by deprecated or non-existent image tags.

**Fix:**

1. Update the image tag in the manifest to a valid version.
2. Force-load the image into Minikube:
```bash
minikube image load <image>:<tag>
```

3. Ensure the manifest uses `imagePullPolicy: Never` for locally loaded images.

---

## 8. Minikube Tunnel — Ingress unreachable

**Symptom:** `.local` domains don't load. The Ingress shows no EXTERNAL-IP.

**Cause:** The tunnel systemd service ran as an unprivileged user or started before Minikube was ready.

**Fix:**

1. Kill the existing tunnel:
```bash
sudo pkill -f "minikube tunnel"
```

2. Clean up stale routes:
```bash
sudo minikube tunnel --cleanup
```

3. Restart via the startup script (handles permissions and timing automatically):
```bash
./start_all.sh
```

4. Verify `/etc/hosts` points to the correct Minikube IP:
```bash
minikube ip
cat /etc/hosts | grep k8s
```

> The tunnel systemd service must run with `User=root` and have `MINIKUBE_HOME` and `KUBECONFIG` pointing to the real user's home directory.

---

## 9. Redis — CrashLoopBackOff (race condition with Sealed Secrets)

**Symptom:** Redis pods crash on startup with a missing Secret error, even though the Sealed Secret manifest was applied.

**Cause:** Redis starts before the Sealed Secrets controller finishes decrypting and creating the actual Secret. The pod tries to mount a Secret that doesn't exist yet.

**Fix:** The deployment includes an `initContainer` that actively waits until the Secret is available before allowing the main container to start:

```yaml
initContainers:
  - name: wait-for-secret
    image: bitnami/kubectl
    command:
      - sh
      - -c
      - |
        until kubectl get secret redis-secret -n databases; do
          echo "Waiting for redis-secret..."; sleep 2;
        done
```

If the issue reappears after a cluster rebuild, verify the Sealed Secrets controller is Running before applying other manifests:
```bash
kubectl get pods -n kube-system | grep sealed-secrets
```

---

## 10. KEDA — New pods stuck in Pending

**Symptom:** KEDA triggers scaling but new WordPress pods remain in `Pending` state. No error is visible in KEDA logs.

**Cause:** The namespace `ResourceQuota` allows fewer pods than KEDA tries to create. The quota error is not surfaced in KEDA's own logs.

**Fix:**

1. Check the current quota usage:
```bash
kubectl describe resourcequota -n wordpress
```

2. Check for quota-related events:
```bash
kubectl get events -n wordpress --sort-by='.lastTimestamp' | grep -i quota
```

3. Update the ResourceQuota to accommodate KEDA's `maxReplicaCount` plus margin for sidecars and temporary jobs:
```bash
kubectl edit resourcequota -n wordpress
```

> Rule: `ResourceQuota.pods` must be ≥ `maxReplicaCount` + 2 (margin for sidecars and backup jobs).
