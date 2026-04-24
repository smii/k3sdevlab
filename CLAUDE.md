# CLAUDE.md — k3sdevlab Homelab Reference
# Branch: develop · ArgoCD GitOps · K3s single-node

## OVERVIEW

K3s homelab managed via ArgoCD GitOps. All apps are declared in `argocd/applications/`
and configured via `charts/*/values.yaml`. Pushing to `develop` triggers auto-sync.

Active env file: `.env` (never `.env_test`)
Installer: `./installer.sh` (bootstraps K3s + ArgoCD only — do not modify)

---

# K8s SRE Agent Guide
---
## Specialized Resources
- **Troubleshooting**: Use the `k8s-diagnostics` skill for initial error analysis (k8sgpt).
- **Deep Architecture**: Delegate to the `kubernetes-specialist` subagent for complex YAML refactoring or networking issues.

## Combined Workflow
1. When a pod fails, first invoke `/k8s-diagnostics` to get an AI-distilled reason.
2. If the fix requires a complex change (e.g., Service Mesh or RBAC), spawn a task for the `kubernetes-specialist` subagent to ensure best practices from its internal playbook.


## Tech Stack
- Infrastructure: Kubernetes (EKS/GKE), Terraform
- Tools: kubectl, k8sgpt, helm, argocd

## Debugging Workflow
1. Check pod status: `kubectl get pods -A`
2. Inspect events: `kubectl get events --sort-by='.lastTimestamp'`
3. Analyze with AI: `k8sgpt analyze --namespace <ns>`
4. Suggest fix using Claude 4.5/4.6 reasoning.

## URLS & NAMESPACES

| App | URL | Namespace | Auth |
|-----|-----|-----------|------|
| **Homepage** | https://portal.rtm.kubernative.io | homepage | forward-auth |
| ArgoCD | https://argocd.rtm.kubernative.io | argocd | OIDC + forward-auth |
| Authelia | https://authelia.rtm.kubernative.io | authelia | native |
| Grafana | https://grafana.rtm.kubernative.io | monitoring | OIDC + forward-auth |
| Gitea | https://git.rtm.kubernative.io | gitea | OIDC + forward-auth |
| Harbor | https://allaboard.rtm.kubernative.io | harbor | OIDC + forward-auth |
| Uptime Kuma | https://uptime.rtm.kubernative.io | uptime-kuma | forward-auth |
| Prometheus | https://prometheus.rtm.kubernative.io | monitoring | forward-auth |
| Traefik | https://traefik.rtm.kubernative.io | traefik-system | forward-auth |
| Falco | https://falco.rtm.kubernative.io | falco | forward-auth |
| Tekton | https://tekton.rtm.kubernative.io | tekton-pipelines | forward-auth |
| Loki | — (Grafana datasource only) | logging | internal |
| CrowdSec | — (Traefik bouncer only) | crowdsec | internal |
| Hugo Blog | https://blog.rtm.kubernative.io | hugo-blog | forward-auth |
| Mailcow | https://mymail.rtm.kubernative.io | mailcow | forward-auth (optional) |

Internal domain: `*.rtm.kubernative.io` → `<NODE_IP>` (dnsmasq on ASUSWRT router — see `.env`)
Public domain: `kubernative.io` (TransIP DNS)

---

## ARCHITECTURE

```
Internet / Browser
        │
        ▼ :443 HTTPS
┌────────────────────┐
│      Traefik       │  ingress controller + TLS termination
│  (traefik-system)  │  cert-manager issues LE certs (HTTP-01)
│                    │  CrowdSec bouncer plugin (IP banning)
└────────┬───────────┘
         │
         │  traefik.ingress.kubernetes.io/router.middlewares:
         │  "authelia-forwardauth@kubernetescrd"
         ▼
┌────────────────────┐
│      Authelia      │  SSO gateway (forward-auth)
│     (authelia)     │  SQLite DB on PVC, TOTP-only
│                    │  OIDC provider for: ArgoCD, Gitea,
│                    │  Grafana, Harbor
└────────┬───────────┘
         │ auth OK → route to app
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                         APPLICATIONS                            │
│                                                                 │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────┐  │
│  │Homepage │  │  Gitea  │  │ Harbor  │  │   Hugo Blog     │  │
│  │(portal) │  │  (git)  │  │(registry│  │   (hugo-blog)   │  │
│  │homepage │  │gitea ns │  │harbor ns│  │                 │  │
│  └─────────┘  └─────────┘  └─────────┘  └─────────────────┘  │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────────┐  │
│  │ Grafana │  │Prometheus│  │  Loki   │  │  Uptime Kuma    │  │
│  │+Alertmgr│  │ (metrics│  │+FlntBit │  │  (uptime-kuma)  │  │
│  │monitoring│  │scraping)│  │ logging │  │                 │  │
│  └─────────┘  └─────────┘  └─────────┘  └─────────────────┘  │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │  Falco  │  │CrowdSec │  │ Tekton  │                      │
│  │(runtime │  │  (IDS/  │  │ (CI/CD  │                      │
│  │security)│  │bouncer) │  │pipeline)│                      │
│  └─────────┘  └─────────┘  └─────────┘  └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────┐
│    K3s / K8s API   │  single-node, local-path storage
│   cert-manager     │  sealed-secrets, metrics-server
│   ArgoCD           │  GitOps: git push → auto-sync
└────────────────────┘
```

### Data flows
- **Metrics**: All apps → Prometheus (scrape) → Grafana (visualize)
- **Logs**: All pods → Fluent-Bit → Loki → Grafana
- **Security events**: Falco → Falcosidekick → Falcosidekick-UI
- **Threat intelligence**: CrowdSec agent → LAPI → Traefik bouncer (ban IPs)
- **CI/CD**: Git push → Tekton → kaniko build → Harbor → ArgoCD deploy
- **Auth flow**: Browser → Traefik → Authelia forward-auth → App

### Memory consumption baseline (2026-04-02)

| Pod | Actual | Limit | Notes |
|-----|--------|-------|-------|
| prometheus | 821Mi | 1Gi | WAL compression + 7d retention enabled |
| grafana | 512Mi | 512Mi | includes sidecar containers |
| argocd-app-controller | 393Mi | unlimited | watches all cluster resources |
| loki | 319Mi | 768Mi | 7-day log retention |
| homepage | ~150Mi | 512Mi | Next.js dashboard (stateless) |
| falco-sidekick-ui-redis | 247Mi | 128Mi | Redis for Falco UI events |
| uptime-kuma | 203Mi | 256Mi | Node.js monitor |
| Node total | ~8.8Gi | 15.3Gi | 57% used |

### Resource tuning strategy
- Use **low requests** (10-50Mi) to allow scheduling, **realistic limits** to prevent OOM kill
- Prometheus: 7-day retention + WAL compression saves ~400Mi vs defaults
- Sample-app deployment scaled to 0 until Tekton builds the image

---

## ARCHITECTURE — WHAT IS ALREADY DONE

### Ingress & TLS
- **Traefik** is the ingress controller (`ingressClassName: traefik`)
- **cert-manager** issues Let's Encrypt certs via HTTP-01 ACME
- ClusterIssuer: `letsencrypt-prod` in `installer/cluster-issuer-le-prod.yaml`
  - Uses `ingressClassName: traefik` (NOT the deprecated `class: traefik`)
- All app ingresses have `cert-manager.io/cluster-issuer: letsencrypt-prod` + TLS blocks
- All externally-accessible apps have valid LE certs

### Authelia SSO
- Every ingress (except Authelia itself) carries:
  ```
  traefik.ingress.kubernetes.io/router.middlewares: "authelia-forwardauth@kubernetescrd"
  ```
- The Traefik Middleware CRD is at `k8s-manifests/authelia-middleware.yaml`
  - Name: `forwardauth`, namespace: `authelia`
  - Annotation format: `authelia-forwardauth@kubernetescrd` (namespace-name@kubernetescrd)
- Authelia config: `charts/authelia/authelia-values.yaml`
  - No SMTP — filesystem notifier only: `/tmp/authelia-notifications.log`
  - TOTP only (WebAuthn disabled)
  - File-based users: `/config/users.yml` (mounted from `authelia-users` secret)
  - SQLite DB at `/config/db.sqlite3` on a 100Mi PVC (`persistence.enabled: true`)
  - Password reset disabled

### Authelia — Critical Helm Chart Quirks
- **Secret rotation**: The chart generates random keys on every `helm upgrade`.
  This was breaking the SQLite DB (encryption key mismatch).
  **Fix applied**: `secret.disabled: false` + `secret.existingSecret: 'authelia'` in values,
  AND secret annotated `helm.sh/resource-policy=keep` with NO `argocd.argoproj.io/tracking-id`.
  - `existingSecret: 'authelia'` → chart uses existing secret, skips creating a new one
  - `disabled: false` → chart writes proper file paths into configmap (REQUIRED)
  - `helm.sh/resource-policy=keep` → Helm never deletes the secret
  - **No ArgoCD tracking-id** → ArgoCD never prunes the secret on sync
  - **Do NOT set `disabled: true`** — that leaves placeholder strings in the configmap;
    the encryption_key file is mounted but never referenced, causing CrashLoopBackOff
  - **Do NOT use `additionalSecrets`** as a workaround — same problem as `disabled: true`
- **Secret file paths**: With `existingSecret`, files land at `/secrets/internal/<key>` inside the pod
  (e.g. `/secrets/internal/storage.encryption.key`). This is the chart's internal mount sub-path.
- **Configuration path**: `/configuration.yaml` (root of pod, NOT `/config/configuration.yaml`)
- **PVC mount**: PVC `authelia` (100Mi) mounts at `/config/`
- **YAML quoting bug**: `filename: '/tmp/...'` renders as `''/tmp/...''` in configmap.
  Always use unquoted: `filename: /tmp/authelia-notifications.log`
- **Dex**: Disabled (`dex.enabled: false`) — ArgoCD uses Authelia OIDC directly

### Falco — Container Runtime Security
- Deployed as part of the base security stack (namespace: `falco`)
- ArgoCD app: `argocd/applications/security/falco.yaml`
- Components: `falco` DaemonSet + `falcosidekick` + `falcosidekick-ui` (web dashboard)
- Driver: `modern_ebpf` — works on kernel 5.8+ without kernel headers (K3s 6.8.x qualifies)
- Containerd socket: `/run/k3s/containerd/containerd.sock`
- UI: `https://falco.rtm.kubernative.io` — protected by Authelia forward-auth
- UI basic auth is disabled (`disableauth: true`) — Authelia handles all auth
- ACL: `admins`/`viewers` via wildcard; `devops_*`/`platform_*` via specific rules
- K3s containerd socket path differs from standard Docker — must be set explicitly in values
- `watch_config_files: false` required — inotify handler init fails on this node; config changes take effect via pod restart (ArgoCD sync) instead of live reload
- Chart pinned to 7.2.1 (Falco 0.42.1) — 8.x introduces inotify regression regardless of driver type
- Default rules are noisy; fluent-bit/argocd/grafana-sidecar all trigger "Contact K8S API Server From Container" — add `customRules` to suppress expected cluster traffic

### OIDC Clients (in authelia-values.yaml)
| Client ID | App | Redirect URI |
|-----------|-----|-------------|
| `gitea` | Gitea | `https://git.rtm.kubernative.io/user/oauth2/authelia/callback` |
| `grafana` | Grafana | `https://grafana.rtm.kubernative.io/login/generic_oauth` |
| `argocd` | ArgoCD | `https://argocd.rtm.kubernative.io/auth/callback` |
| `harbor` | Harbor | `https://allaboard.rtm.kubernative.io/c/oidc/callback` |

Secrets are stored in `charts/authelia/authelia-values.yaml` — do not duplicate here.

> **Homepage** does NOT use OIDC — it uses Authelia forward-auth only.

### ArgoCD SSO
- Configured in `charts/argocd/argocd-values.yaml`
- `oidc.config` points to Authelia issuer
- RBAC: `admins`/`devops_prd` → `role:admin`, `devops_dev`/`devops_test` → sync-only, others → readonly
- ArgoCD is managed by direct `helm upgrade` (not via ArgoCD self-management):
  ```bash
  helm upgrade argocd argo/argo-cd --namespace argocd --values charts/argocd/argocd-values.yaml
  ```
- ArgoCD repo: `https://github.com/smii/k3sdevlab` (HTTPS only — no SSH key in ArgoCD)

### Groups & Access Policy
Group naming: `<project>_dev` | `<project>_test` | `<project>_prd`

| Group type | Authelia policy | ArgoCD role |
|---|---|---|
| admins | one_factor (all domains) | admin |
| viewers | one_factor (all domains) | readonly |
| *_dev, *_test | one_factor (project domains) | readonly / devops: sync |
| *_prd | two_factor (project domains) | admin (devops_prd) / readonly |

### TOTP
- Pre-registered for all 14 users via CLI (bypasses identity-verification web flow)
- TOTP URIs in `docs/authelia-totp.md`
- To re-register a user:
  ```bash
  POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
  kubectl exec -n authelia $POD -- authelia storage user totp generate <user> --config /configuration.yaml --force
  ```

### Users (`authelia-users.yml`)
All 14 personas (argon2id hashed). Credentials are in `authelia-users.yml` — do not commit plaintext passwords here.

---

## HOW TO MAKE CHANGES

### Modify an app
Edit `charts/<app>/<app>-values.yaml` and push. ArgoCD auto-syncs.

### Add a new app
1. Create `argocd/applications/<category>/<app>.yaml`
2. Create `charts/<app>/<app>-values.yaml` with:
   ```yaml
   ingress:
     annotations:
       traefik.ingress.kubernetes.io/router.middlewares: "authelia-forwardauth@kubernetescrd"
       cert-manager.io/cluster-issuer: letsencrypt-prod
     tls:
       - secretName: <app>-tls
         hosts:
           - <hostname>.rtm.kubernative.io
   ```
3. Push — ArgoCD deploys.

### Authelia config changes
Edit `charts/authelia/authelia-values.yaml` and push.
ArgoCD syncs → new Authelia configmap → pod restarts.
The secret is NOT touched (annotated `helm.sh/resource-policy=keep`).

### Authelia DB wiped / encryption key mismatch
```bash
# 1. Delete stale DB
kubectl run authelia-db-reset --rm -i --restart=Never \
  --image=busybox \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"authelia"}}],"containers":[{"name":"authelia-db-reset","image":"busybox","command":["sh","-c","rm -f /config/db.sqlite3 && echo DELETED"],"volumeMounts":[{"name":"data","mountPath":"/config"}]}]}}' \
  -n authelia

# 2. Restart immediately (before any crashing pod recreates a bad DB)
kubectl rollout restart daemonset/authelia -n authelia
kubectl rollout status daemonset/authelia -n authelia

# 3. Re-register all TOTP secrets
POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
for user in smii alice bob carol dave eve frank grace henry ivan judy karl linda viewer; do
  kubectl exec -n authelia $POD -- authelia storage user totp generate $user --config /configuration.yaml --force 2>&1
done
```

---

## VAGRANT DEV ENVIRONMENT

Single-command local replica of the full stack for development and testing.

### Quick start
```bash
vagrant up                            # lite profile — 8 GB RAM (recommended)
VAGRANT_PROFILE=full vagrant up       # full profile — 12 GB RAM (adds Harbor/Loki/CrowdSec)
VAGRANT_VM_IP=10.10.10.10 vagrant up  # custom IP if 192.168.56.100 conflicts
```

### How it works
- **DNS**: nip.io wildcard — `*.192.168.56.100.nip.io` resolves to the VM's IP on the public
  internet. No `/etc/hosts` changes needed on the host.
- **TLS**: Self-signed CA via cert-manager (`ClusterIssuer: vagrant-ca`). Run `bash vagrant/trust-ca.sh`
  once on your host to install the CA and remove browser warnings.
- **Git**: `vagrant/provision.sh` patches all domain/issuer references, creates a local bare git
  repo, and serves it via `git-daemon` on port 9418. ArgoCD uses `git://<VM_IP>/homelab.git`
  instead of GitHub — fully offline.
- **Let's Encrypt / public domain**: Not needed. The Vagrant environment substitutes
  `letsencrypt-prod` with `vagrant-ca` and uses `.nip.io` instead of `kubernative.io`.

### Key files
| File | Purpose |
|------|---------|
| `Vagrantfile` | VM spec — VirtualBox (default) or libvirt |
| `vagrant/provision.sh` | Full provisioner — idempotent, safe to re-run with `vagrant provision` |
| `vagrant/cluster-issuer-ca.yaml` | cert-manager ClusterIssuer using the local CA |
| `vagrant/trust-ca.sh` | Install the CA on the host (macOS, Linux, Windows) |

### Profiles
| Profile | RAM | What's excluded |
|---------|-----|-----------------|
| `lite` (default) | 8 GB | Harbor, CrowdSec, Loki, Fluent-Bit |
| `full` | 12 GB | Nothing |

### Credentials (all services)
See `authelia-users.yml` for user list. ArgoCD admin: `admin` / `<ARGOCD_ADMIN_PASSWORD from .env.vagrant>`

### What provision.sh does
1. Installs system packages (including `apache2-utils` for `htpasswd`)
2. Copies the repo to `/opt/homelab` and patches: domains → nip.io, issuer → vagrant-ca, git remote → local; `chmod -x scripts/update-configs.sh` to prevent template regeneration
3. Creates `/srv/git/homelab.git` and starts `git-daemon.service` on port 9418
4. Installs K3s (Traefik disabled), Helm, cert-manager
5. Generates a 4096-bit self-signed CA at `/etc/ssl/vagrant-ca/ca.crt` and creates `ClusterIssuer: vagrant-ca`
6. **Pre-creates the `authelia` namespace + K8s secrets** (`authelia` and `authelia-users`) before installer.sh runs — required because the Helm chart uses `existingSecret: 'authelia'` and ArgoCD would otherwise deploy the pod before the secret exists
7. Runs `installer.sh .env.vagrant` → ArgoCD deploys all apps via GitOps
8. Waits for Authelia and registers TOTP for all 14 test users

### Vagrant gotchas
| Gotcha | Detail |
|--------|--------|
| `scripts/update-configs.sh` disabled | provision.sh `chmod -x`s it so installer.sh doesn't regenerate templates over patched values |
| Authelia secrets pre-created | provision.sh creates the `authelia` K8s secret and `authelia-users` secret in the `authelia` namespace BEFORE `installer.sh` runs. Without this, ArgoCD deploys Authelia before the secret exists and the pod CrashLoops. The secrets are annotated `helm.sh/resource-policy=keep` with NO `argocd.argoproj.io/tracking-id` |
| `ORG_STRUCTURE_ENABLED=false` | Gitea orgs are skipped at install time (Gitea isn't ready yet). Set up manually after if needed |
| ArgoCD sync takes ~10 min | Apps deploy in waves. Check progress at `https://argocd.<VM_IP>.nip.io` |
| git-daemon port 9418 | ArgoCD pulls from `git://<VM_IP>/homelab.git`. If this port is firewalled inside the VM, ArgoCD will fail to sync |
| nip.io needs internet | nip.io is a public DNS service. The VM needs outbound internet for DNS lookups. The apps themselves run offline |
| authelia-users secret namespace | The `authelia-users` secret must be in the `authelia` namespace. `installer.sh`'s built-in `create_authelia_users_secret` creates it in `security` — provision.sh overrides this by pre-creating it in the correct namespace |

---

## TEKTON CI/CD

### Overview
- Tekton Pipelines + Dashboard deployed via ArgoCD (namespace: `tekton-pipelines`)
- Dashboard URL: `https://tekton.rtm.kubernative.io`
- Access: `devops_*` and `admins` groups only (Authelia forward-auth)

### Sample App Pipeline
- Source: `apps/sample-app/` in this repo
- Pipeline: `tekton/pipelines/sample-app-pipeline.yaml`
- Builds with kaniko (no Docker daemon needed in K3s)
- Pushes to Harbor: `allaboard.rtm.kubernative.io/library/sample-app:latest`
- ArgoCD deploys from `apps/sample-app/k8s/`
- Metrics scraped by Prometheus, visible in Grafana
- **Deployment scaled to `replicas: 1`** — image built and pushed by Tekton, running

### Running a build
```bash
# Trigger a pipeline run (always use create, not apply — generateName is used)
kubectl create -f tekton/pipelineruns/sample-app-run.yaml

# Watch progress
kubectl get pipelineruns -n tekton-pipelines -w

# View logs for a specific task run
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<run-name> --all-containers
```

### Harbor credentials secret
Must be created manually before first run (not committed to Git).
**Use the internal Harbor service URL to bypass Traefik/Authelia from inside the cluster**:
```bash
# For Tekton pipeline (kaniko push — needs internal URL, HTTP)
kubectl create secret docker-registry harbor-credentials \
  --docker-server=harbor-core.harbor \
  --docker-username=<user> \
  --docker-password=<password> \
  -n tekton-pipelines

# For sample-app deployment (kubelet image pull — uses external URL, HTTPS)
# Authelia bypasses /v2/ and /service/token for allaboard.rtm.kubernative.io
kubectl create secret docker-registry harbor-credentials \
  --docker-server=allaboard.rtm.kubernative.io \
  --docker-username=<user> \
  --docker-password=<password> \
  -n sample-app
```

### Grafana dashboards
Two dashboards are pre-loaded via ConfigMap (label `grafana_dashboard: "1"`, picked up by Grafana sidecar):
- "Sample App" (`k8s-manifests/grafana-dashboard-sample-app.yaml`) — HTTP request rate, error rate, p50/p95/p99 latency, active requests
- "Tekton Pipelines" (`k8s-manifests/grafana-dashboard-tekton.yaml`) — pipeline run status, duration, success rate

---

## KNOWN GOTCHAS

| Gotcha | Detail |
|--------|--------|
| ArgoCD managed by Helm directly | Not self-managed. Use `helm upgrade` to apply `charts/argocd/argocd-values.yaml` |
| Authelia secret mount | **Definitive pattern**: `secret.disabled: false` + `secret.existingSecret: 'authelia'`. `disabled: true` mounts files but leaves placeholder strings in the configmap — encryption_key is never read. `existingSecret` makes the chart write proper file paths into the configmap without rendering a new Secret manifest. |
| Authelia secret must not be regenerated | Secret created manually, annotated `helm.sh/resource-policy=keep` and **must NOT have** `argocd.argoproj.io/tracking-id`. If the tracking-id is present, ArgoCD prunes the secret when Helm stops rendering it — even with `helm.sh/resource-policy: keep` (that annotation only stops Helm, not ArgoCD). Remove with: `kubectl annotate secret authelia -n authelia argocd.argoproj.io/tracking-id-`. If the secret goes missing, extract current values from the running pod at `/secrets/internal/<key>` before it restarts. |
| cert-manager ClusterIssuer | Must use `ingressClassName: traefik` not `class: traefik` (deprecated) |
| Authelia forward-auth on external requests | Traefik strips `X-Forwarded-Method` externally → `/api/authz/forward-auth` returns 400 when tested with curl from outside. Works correctly in production |
| TOTP identity verification | Authelia v4.38+ requires an OTP via notifier before allowing 2FA web enrollment. Bypass: use CLI to pre-register |
| Notification log location | `kubectl exec -n authelia <pod> -- cat /tmp/authelia-notifications.log` |
| ArgoCD initial admin password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |
| uptime-kuma entrypoint restriction | Do NOT add `traefik.ingress.kubernetes.io/router.entrypoints: websecure` — blocks HTTP-01 ACME challenge |
| gitea/harbor OutOfSync | Suppressed via `ignoreDifferences` on PVC storageClassName (gitea) and Secret data (harbor). Apps are healthy — this is drift from immutable/generated fields |
| CrowdSec agent re-registration | When the agent pod restarts with a new name, it tries to re-register with LAPI but gets 403 (already exists). Fix: `kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli machines delete <old-pod-name>` then delete the stuck pod. |
| sample-app ImagePullBackOff | Image won't exist until Tekton builds it. After first Tekton pipeline run, deployment is at `replicas: 1`. |
| Tekton kaniko Harbor auth | Kaniko (build-and-push) must use internal Harbor service URL `harbor-core.harbor/library/...` with `--insecure` flag. Pushing to `allaboard.rtm.kubernative.io` fails because Authelia intercepts the push. |
| Kubelet Harbor image pull | Kubelet uses host DNS (not CoreDNS), so `harbor-core.harbor` can't be resolved. Use external URL `allaboard.rtm.kubernative.io` for image pulls. Add Authelia bypass for `^/v2($|/.*)` and `^/service/token($|\?.*)` on the Harbor domain so Harbor's own JWT auth handles registry pulls instead of Authelia redirecting. Bypass rule must be the FIRST rule in `access_control.rules` — `*.rtm.kubernative.io` catch-all rules fire first otherwise. |
| Tekton PipelineRun uses generateName | Never use `kubectl apply` for PipelineRuns — always use `kubectl create`. `apply` fails with generateName. |
| Tekton git-clone task | Custom task in `tekton/tasks/git-clone-task.yaml` using `alpine/git:2.45.2`. gcr.io/tekton-releases images return 403 (deprecated). Task uses `runAsUser: 1000` with `HOME=/tmp`, `safe.directory *` to handle PVC ownership issues. |
| Homepage ALLOWED_HOSTS | `HOMEPAGE_ALLOWED_HOSTS` must include `$(MY_POD_IP):3000` via `fieldRef: status.podIP` for K8s healthcheck probes to work. Without it, probes fail host validation and the pod CrashLoops. |
| Grafana OIDC role_attribute_path vs ID token | Grafana 12.x evaluates `role_attribute_path` against the **ID token**, not merged userinfo data. If groups are missing from the ID token (Authelia default: groups only via userinfo), the JMESPath expression `contains(groups, 'admins')` evaluates against `null` → falls through to default `Viewer`. Fix: add `claims_policy: 'id_token_groups'` to the Grafana client in Authelia. |
| Falco driver: ebpf not modern_ebpf | `modern_ebpf` causes inotify regression on this node. Chart pinned to 7.2.1 using `ebpf` driver. `watch_config_files: false` required regardless. |
| Grafana OIDC token_endpoint_auth_method | Grafana defaults to `client_secret_basic` for token exchange. If Authelia client has `client_secret_post`, the token exchange fails silently (`Client authentication failed`) — Grafana never gets groups and defaults to `Viewer`. Fix: set `token_endpoint_auth_method: 'client_secret_basic'` on the Grafana client in Authelia. |
| Grafana OIDC role_attribute_path vs ID token | Grafana 12.x evaluates `role_attribute_path` against the **ID token**, not merged userinfo data. If groups are missing from the ID token (Authelia default: groups only via userinfo), the JMESPath expression `contains(groups, 'admins')` evaluates against `null` → falls through to default `Viewer`. Fix: add `claims_policy: 'id_token_groups'` to the Grafana client in Authelia. |
| Grafana allow_assign_grafana_admin | `role_attribute_path` returning `GrafanaAdmin` is silently ignored unless `allow_assign_grafana_admin: true` is set in `grafana.ini` under `auth.generic_oauth`. Without it, user gets `Admin` org role but NOT server-level `isGrafanaAdmin`. |
| Grafana OIDC consent_mode | `consent_mode: 'auto'` on the Authelia client requires interactive consent approval, breaking programmatic OAuth flows. Use `consent_mode: 'implicit'` for Grafana. |
| Homepage/Homarr ingress conflict | Both Homepage and Homarr were configured for `portal.rtm.kubernative.io`. Homarr deployment scaled to 0 to resolve conflict. Homepage is the active dashboard with 9 tabs configured. |
| Tekton Prometheus metrics unavailable | Tekton Controller does not expose Prometheus metrics by default (no ServiceMonitor configured). Dashboard uses iframe embed instead of prometheusmetric widget. |
| Coder service svclb port conflict | Coder service type changed from LoadBalancer to ClusterIP to prevent svclb-coder DaemonSet port conflicts. Service still accessible internally. |

---

## OPTIONAL ADD-ONS

These components are **personal/optional** — not installed by default. Each is controlled by a
feature flag in `.env`. The ArgoCD Application manifest for each lives in
`argocd/applications/addons/`. The installer checks the flags and only applies the
corresponding Application if the flag is `true`.

> **Note**: Falco is NOT in this section — it is part of the base security stack.

Pattern for each add-on:
1. Add `INSTALL_<APP>=false` default to `installer.sh` config_vars section (do not modify installer.sh directly — add via `.env`)
2. Create `argocd/applications/addons/<app>.yaml`
3. Create `charts/<app>/<app>-values.yaml`
4. Add Authelia ACL rules + OIDC client if the app supports OIDC

---

### Homepage — Dashboard (gethomepage.dev)

**Installed by default** — `argocd/applications/apps/homepage.yaml`

| Item | Value |
|------|-------|
| Namespace | `homepage` |
| URL | `https://portal.rtm.kubernative.io` |
| Image | `ghcr.io/gethomepage/homepage:v1.2.0` |
| SSO | Authelia forward-auth (no OIDC needed) |
| Config | ConfigMap `homepage` in `k8s-manifests/homepage/` |

**Dashboard features** — 9 tabs (Overview, Notes, Infrastructure, Services, Security, Monitoring, Cluster Panels, CI/CD, Operations):
- **Overview**: k3sdevlab GitHub link, ArgoCD (apps/synced/outOfSync/healthy with highlights), Grafana (dashboards/datasources/alerts), Prometheus (targets up/down/total with highlights), Uptime Kuma siteMonitor
- **Notes**: Static informational widget with dashboard summary and edit instructions
- **Infrastructure**: Traefik (routers/services/middleware counts), Authelia (auth success/denied/total requests via Prometheus), cert-manager (K8s app status), Loki (K8s app status)
- **Services**: Gitea (repos/issues/PRs/notifications), Harbor (projects/repos/storage), Hugo Blog (link, check Loki for access logs)
- **Security**: CrowdSec (alerts/bans), Falco Events (Total/Critical/Error/Warning/Notice/Events per min with highlights on Critical/Error), Harbor Security (repositories from library project)
- **Monitoring**: Grafana-Loki Stack (Loki CPU/Memory, Grafana CPU/Memory via prometheusmetric), Namespace Memory (top 4: monitoring/argocd/logging/gitea), Namespace CPU (same 4), Node Resources (memory %/CPU load 5m/disk %/network RX)
- **Cluster Panels**: 7 Grafana iframes showing CPU/memory requests/limits/usage over time (from dashboard `efa86fd1d0c121a26444b636a3f509a8`)
- **CI/CD**: Tekton Pipelines (iframe dashboard embed h-96), Harbor Registry (repos/storage), Gitea (repos/issues/PRs), GitHub Stats (k3sdevlab stars/forks/issues/size via public API)
- **Operations**: Loki Logs (Grafana public dashboard iframe), Gitea Stats (repos/issues/PRs)

**Widget enhancements (2026-04-03)**:
- **Falco**: Added Critical priority, Events/min rate, highlight rules for Critical/Error
- **Grafana-Loki**: New widget showing CPU/Memory for both Loki and Grafana pods
- **GitHub**: Public API widget showing k3sdevlab repository stats (no token needed, 120s refresh)  
- **Notes tab**: Static widget with dashboard overview and configuration notes
- **Tekton**: Kept as iframe (Prometheus metrics not available - no ServiceMonitor configured)
- **CrowdSec**: Description updated to "Intrusion Detection + Bans"
- **Harbor Security**: Changed API endpoint from projects/1 to projects/library

**API tokens** stored in `homepage-secrets` Secret (`k8s-manifests/homepage/homepage.yaml`):
- `HOMEPAGE_VAR_ARGOCD_TOKEN` — ArgoCD `homepage` account (role:readonly, apiKey)
- `HOMEPAGE_VAR_GITEA_TOKEN` — Gitea token for `smii` user (read:repository, read:issue, read:notification)
- `HOMEPAGE_VAR_GRAFANA_USER/PASS` — Grafana admin credentials
- `HOMEPAGE_VAR_CROWDSEC_USER/PASS` — CrowdSec LAPI machine credentials

**Gotchas:**
- `HOMEPAGE_ALLOWED_HOSTS` must include `$(MY_POD_IP):3000` via `fieldRef: status.podIP` for probe validation
- CrowdSec LAPI machine credentials change when the LAPI pod restarts with a new name — update homepage-secrets
- Grafana `allow_embedding: true` in grafana.ini required for iframe widgets
- Grafana `auth.anonymous` enabled (Viewer role) so iframe widgets work without double-login — Authelia forward-auth still protects at ingress level
- Config is stateless (ConfigMap) — no PVC needed

---

### Mailcow — Full Mailserver

| Item | Value |
|------|-------|
| Flag | `INSTALL_MAILCOW=true` in `.env` |
| Namespace | `mailcow` |
| URL | `https://mymail.rtm.kubernative.io` (SOGo webmail + admin panel) |
| Deployment | Docker Compose via Mailcow-dockerized OR community Helm chart |
| SSO | Authelia forward-auth for admin panel; SOGo has its own login |

> **Installer pause**: The installer MUST stop after provisioning the namespace and before
> starting Mailcow, to allow you to set the required DNS records (MX, SPF, DKIM, DMARC, PTR)
> at TransIP. Without these, mail delivery will fail silently.

#### Step 1 — Required DNS records at TransIP (`kubernative.io`)

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `mail` | `<PUBLIC_IP>` | 300 |
| MX | `@` | `mail.kubernative.io` (priority 10) | 3600 |
| TXT | `@` | `v=spf1 mx ~all` | 3600 |
| TXT | `mail._domainkey` | *(generated by Mailcow — get from Admin → Configuration → ARC/DKIM Keys after first boot)* | 3600 |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:postmaster@kubernative.io` | 3600 |
| PTR | `<PUBLIC_IP>` | `mail.kubernative.io` | *(set at ISP/VPS — not TransIP)* |

> PTR (reverse DNS) must be set at your ISP or VPS provider for the public IP — not in TransIP.
> Without a matching PTR, most receiving mail servers will reject or spam-folder your outbound mail.

#### Step 2 — Required open ports (router port forwarding → `<NODE_IP>`)

| Port | Protocol | Purpose | Required? |
|------|----------|---------|-----------|
| 25 | TCP | SMTP inbound (receiving mail) | **Yes** |
| 465 | TCP | SMTPS (sending, SSL) | Yes |
| 587 | TCP | Submission (sending, STARTTLS) | Yes |
| 993 | TCP | IMAPS (mail client sync) | Yes |
| 995 | TCP | POP3S (optional — most clients use IMAP) | No |
| 4190 | TCP | ManageSieve (server-side mail filtering) | No |
| 80 | TCP | Already open — ACME HTTP-01 challenge | Yes |
| 443 | TCP | Already open — HTTPS webmail | Yes |

> ISPs sometimes block port 25 on residential lines. Verify with: `nc -zv smtp.gmail.com 25` from
> the server. If blocked, contact ISP or use a smarthost/relay.

#### Step 3 — Mailcow Helm / deployment approach

Mailcow is primarily distributed as Docker Compose. K8s deployment options:
- **Option A (recommended)**: Run Mailcow in its own VM/container outside K3s, proxy via Traefik ExternalName service — keeps mailserver isolation clean
- **Option B**: Use community Helm chart `mailcow` from `https://github.com/mailcow/mailcow-helm` — less mature, but keeps everything in K3s

For Option B, key values (`charts/mailcow/mailcow-values.yaml`):
```yaml
mailcow:
  hostname: mail.kubernative.io
  timezone: Europe/Amsterdam

ingress:
  enabled: true
  ingressClassName: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: "authelia-forwardauth@kubernetescrd"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: mymail.rtm.kubernative.io
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: mailcow-tls
      hosts:
        - mymail.rtm.kubernative.io
```

> The Authelia forward-auth middleware protects the admin panel at `/mailcow-admin`.
> SOGo webmail (`/SOGo`) can be left unprotected or also wrapped — your preference.

**Authelia ACL** — add:
```yaml
- domain: "mymail.rtm.kubernative.io"
  policy: one_factor
  subject:
    - "group:admins"
- domain: "mymail.rtm.kubernative.io"
  policy: bypass
  resources:
    - "^/SOGo.*"    # allow webmail without Authelia login — Mailcow handles its own auth
```

#### Installer pause flow

Add this to the optional installer block:
```bash
if [[ "${INSTALL_MAILCOW}" == "true" ]]; then
  echo ""
  echo "⚠️  MAILCOW REQUIRES MANUAL DNS SETUP — pausing installer."
  echo ""
  echo "Add the following DNS records at your provider (TransIP → kubernative.io):"
  echo "  A     mail.kubernative.io    → <PUBLIC_IP>"
  echo "  MX    kubernative.io         → mail.kubernative.io (priority 10)"
  echo "  TXT   kubernative.io         → v=spf1 mx ~all"
  echo "  TXT   _dmarc.kubernative.io  → v=DMARC1; p=quarantine; rua=mailto:postmaster@kubernative.io"
  echo ""
  echo "Also open these ports on your router (forward to <NODE_IP>):"
  echo "  25, 465, 587, 993, 995, 4190"
  echo ""
  echo "After DNS propagates (check: dig MX kubernative.io), press ENTER to continue."
  read -r
  # Then apply the ArgoCD Application
  kubectl apply -f argocd/applications/addons/mailcow.yaml
  echo "After Mailcow starts, get the DKIM key from Admin → Configuration → ARC/DKIM Keys"
  echo "and add it as TXT mail._domainkey.kubernative.io at TransIP."
fi
```

---

## RESOURCE MANAGEMENT

Single node with ~15.3Gi RAM. Actual usage ~57% (8.8Gi). Strategy: low requests, realistic limits.

### Current limits by service
| Service | CPU req/lim | Memory req/lim | File |
|---------|-------------|----------------|------|
| Prometheus | 50m/1000m | 256Mi/1Gi | `charts/prometheus-stack/prometheus-values.yaml` |
| Grafana | 50m/500m | 128Mi/512Mi | `charts/prometheus-stack/prometheus-values.yaml` |
| Loki | 50m/500m | 128Mi/768Mi | `charts/grafana-loki/loki-values.yaml` |
| Uptime Kuma | 10m/200m | 64Mi/256Mi | `charts/uptime-kuma/uptime-kuma-values.yaml` |
| Falco sidekick | 10m/200m | 32Mi/128Mi | `charts/falco/falco-values.yaml` |
| Falco sidekick-ui | 10m/200m | 32Mi/128Mi | `charts/falco/falco-values.yaml` |
| Falco sidekick-ui-redis | 10m/100m | 32Mi/128Mi | `charts/falco/falco-values.yaml` |
| CrowdSec agent | 10m/200m | 32Mi/192Mi | `charts/crowdsec/security-engine-values.yaml` |
| CrowdSec LAPI | 10m/300m | 64Mi/256Mi | `charts/crowdsec/security-engine-values.yaml` |

### Prometheus tuning
- `retention: 7d` — 7 days instead of 15d default
- `walCompression: true` — reduces WAL memory footprint
- `scrapeInterval: 60s` — 60s instead of 30s default (halves time-series load)
- `storage.tsdb.min-block-duration: 2h` — faster compaction, less memory during compaction

---

## CONSTRAINTS

- Do NOT modify `installer.sh`
- Do NOT add SMTP config to Authelia — filesystem notifier only (Mailcow is a separate service)
- Do NOT use `.env_test` — active file is `.env`
- Do NOT commit plaintext passwords, IPs, or OIDC secrets to CLAUDE.md — reference the source files
- Domain convention: `*.rtm.kubernative.io` for internal, `kubernative.io` for public
- Group names use underscores: `homelab_dev` not `homelab-dev`
- Authelia middleware annotation: `authelia-forwardauth@kubernetescrd`
- ArgoCD repo source: HTTPS only (`https://github.com/smii/k3sdevlab`) for production
- Optional add-ons go in `argocd/applications/addons/` — NOT in core `argocd/applications/`
- Optional add-on flags default to `false` in installer; enable per-environment in `.env`
