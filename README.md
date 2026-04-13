# K3s Homelab — Self-Hosted Private Coding Environment

A ready-to-go, self-hosted coding environment built on K3s and managed entirely through ArgoCD GitOps. It ships with everything a small engineering team needs out of the box: Git hosting, a container registry, CI/CD pipelines, remote development workspaces, full observability, and runtime security — all behind a single SSO layer.

The access model is built around a standardised `<project>_dev / _test / _prd` group structure that maps directly to AD group names. Every downstream tool (ArgoCD, Gitea, Grafana, Harbor, Coder) is already wired to consume those groups via OIDC. Swapping Authelia for an enterprise IDP — Active Directory, Okta, Keycloak — requires only re-pointing the OIDC issuer; all access policies, RBAC rules, and role mappings carry over unchanged.

> Entirely vibe-coded using [Claude](https://claude.ai) (Claude Code CLI) across ~209 commits — from initial K3s bootstrap through Tekton pipelines, Falco eBPF security, and a 9-tab Homepage dashboard.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Local Development (Vagrant)](#local-development-vagrant)
- [Architecture](#architecture)
- [Components](#components)
- [Repository Structure](#repository-structure)
- [Authentication (Authelia SSO)](#authentication-authelia-sso)
  - [Groups](#groups)
  - [Access Policy](#access-policy)
  - [2FA / TOTP](#2fa)
  - [Test Users](#test-users)
  - [Changing Default Passwords](#changing-default-passwords)
- [Deployment](#deployment)
- [ArgoCD](#argocd)
- [CI/CD with Tekton](#cicd-with-tekton)
- [Sync Waves](#sync-waves)
- [Troubleshooting](#troubleshooting)
- [Test Environment](#test-environment)

---

## Quick Start

```bash
git clone https://github.com/smii/k3sdevlab.git
cd k3sdevlab

cp .env.example .env
nano .env   # set your domains and passwords

chmod +x installer.sh
./installer.sh
```

The installer bootstraps K3s and ArgoCD only. ArgoCD then deploys everything else from this repo.

---

## Local Development (Vagrant)

Run the full stack locally in a single VM — no cloud, no DNS changes, no Let's Encrypt required.

### Prerequisites

- [VirtualBox](https://www.virtualbox.org/) (default) **or** [libvirt/KVM](https://libvirt.org/) with `vagrant plugin install vagrant-libvirt`
- [Vagrant](https://www.vagrantup.com/) ≥ 2.3
- 8 GB free RAM (lite profile) or 12 GB (full profile)

### Quick start

```bash
vagrant up                              # lite profile — 8 GB RAM (recommended)
VAGRANT_PROFILE=full vagrant up         # full profile — 12 GB RAM (adds Harbor, Loki, CrowdSec)
VAGRANT_VM_IP=10.10.10.10 vagrant up    # custom IP if 192.168.56.100 conflicts on your network
```

Provisioning takes ~15 minutes on first run. All services will be available at `*.<VM_IP>.nip.io` from your host browser — no `/etc/hosts` edits required.

### Trust the self-signed CA (one-time, eliminates browser warnings)

```bash
bash vagrant/trust-ca.sh
```

Supports macOS, Linux (Debian/RHEL), and Windows. Without this step, browsers will show a TLS warning for each service — you can still proceed, it's just a self-signed CA.

### Services

After `vagrant up`, all services are reachable at `https://<name>.<VM_IP>.nip.io`:

| Service | URL (default IP) |
|---------|-----------------|
| Homepage | https://portal.192.168.56.100.nip.io |
| ArgoCD | https://argocd.192.168.56.100.nip.io |
| Authelia | https://authelia.192.168.56.100.nip.io |
| Grafana | https://grafana.192.168.56.100.nip.io |
| Gitea | https://git.192.168.56.100.nip.io |
| Harbor | https://allaboard.192.168.56.100.nip.io |
| Prometheus | https://prometheus.192.168.56.100.nip.io |
| Traefik | https://traefik.192.168.56.100.nip.io |
| Uptime Kuma | https://uptime.192.168.56.100.nip.io |
| Falco UI | https://falco.192.168.56.100.nip.io |
| Coder | https://realcoder.192.168.56.100.nip.io |
| Tekton Dashboard | https://tekton.192.168.56.100.nip.io |
| Sample App | https://sample-app.192.168.56.100.nip.io |

### Credentials

| Service | Username | Password |
|---------|----------|----------|
| All SSO-protected services | `smii` | `Homelab2024!` |
| ArgoCD admin | `admin` | `Homelab2024!` |

TOTP is pre-registered for all 14 test users — on first login you'll go straight to the TOTP prompt. Import the TOTP URI from `docs/authelia-totp.md` into any authenticator app.

### Profiles

| Profile | RAM | Excluded apps |
|---------|-----|---------------|
| `lite` (default) | 8 GB | Harbor, CrowdSec, Loki, Fluent-Bit |
| `full` | 12 GB | — |

### Re-provisioning

```bash
vagrant provision   # re-run provisioner (idempotent — safe to run multiple times)
vagrant reload      # restart VM without reprovisioning
vagrant destroy -f && vagrant up  # full reset
```

### How it works

| Concern | Production | Vagrant |
|---------|-----------|---------|
| DNS | `*.your.domain.com` via dnsmasq | `*.<VM_IP>.nip.io` — public wildcard DNS, no config needed |
| TLS | Let's Encrypt (HTTP-01) | Self-signed CA (`vagrant-ca` ClusterIssuer) |
| Git source | `https://github.com/smii/k3sdevlab` | `git://<VM_IP>/homelab.git` via git-daemon (port 9418) |
| Domain patching | n/a | `provision.sh` rewrites all YAML in the VM before ArgoCD syncs |

### Troubleshooting Vagrant

```bash
# SSH into the VM
vagrant ssh

# Follow ArgoCD sync progress (inside VM)
watch kubectl get apps -n argocd

# Check a specific app
kubectl describe application authelia -n argocd

# Authelia logs (inside VM)
kubectl logs -n authelia daemonset/authelia --tail=50

# If nip.io DNS isn't resolving — the VM needs outbound internet access
# nip.io is a public DNS service; the apps themselves run fully offline
```

---

## Architecture

<details>
<summary>Click to expand architecture diagram</summary>

```
Internet / Browser
        │
        ▼ :443 HTTPS
┌────────────────────────────────┐
│            Traefik             │  Ingress controller + TLS termination
│        (traefik-system)        │  cert-manager → Let's Encrypt (HTTP-01)
│                                │  CrowdSec bouncer plugin (IP banning)
└───────────────┬────────────────┘
                │  traefik.ingress.kubernetes.io/router.middlewares:
                │  "authelia-forwardauth@kubernetescrd"
                ▼
┌────────────────────────────────┐
│            Authelia            │  SSO gateway (forward-auth)
│          (authelia)            │  TOTP-only · OIDC provider
│                                │  SQLite DB on PVC · file-based users
└───────────────┬────────────────┘
                │ auth OK → route to app
                ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                              APPLICATIONS                                 │
│                                                                           │
│  ┌─────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │  Homepage   │  │  Gitea   │  │  Harbor  │  │     Hugo Blog        │ │
│  │  (portal)   │  │  (git)   │  │(registry)│  │    (hugo-blog)       │ │
│  │  homepage   │  │  gitea   │  │  harbor  │  │                      │ │
│  └─────────────┘  └──────────┘  └──────────┘  └──────────────────────┘ │
│  ┌─────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │   Grafana   │  │Prometheus│  │   Loki   │  │    Uptime Kuma       │ │
│  │  +Alertmgr  │  │ (metrics)│  │+FluentBit│  │   (uptime-kuma)      │ │
│  │  monitoring │  │monitoring│  │  logging │  │                      │ │
│  └─────────────┘  └──────────┘  └──────────┘  └──────────────────────┘ │
│  ┌─────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │    Falco    │  │ CrowdSec │  │  Tekton  │  │    Coder             │ │
│  │  (runtime   │  │  (IDS /  │  │  (CI/CD  │  │ (remote dev · OIDC)  │ │
│  │  security)  │  │ bouncer) │  │ pipeline)│  │        coder         │ │
│  └─────────────┘  └──────────┘  └──────────┘  └──────────────────────┘ │
│  ┌─────────────┐  ┌──────────┐                                          │
│  │Pingvin Share│  │ Sample   │                                          │
│  │(file share) │  │   App    │                                          │
│  │  sharing    │  │sample-app│                                          │
│  └─────────────┘  └──────────┘                                          │
└───────────────────────────────────────────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────┐
│       K3s / K8s API            │  Single-node, local-path storage
│   cert-manager · ArgoCD        │  GitOps: git push → auto-sync
│   Sealed Secrets               │  Encrypted secrets in Git
└────────────────────────────────┘
```

**Data flows**
- **Metrics**: All apps → Prometheus (scrape) → Grafana (visualize)
- **Logs**: All pods → Fluent-Bit → Loki → Grafana
- **Security events**: Falco → Falcosidekick → Falcosidekick-UI
- **Threat intelligence**: CrowdSec agent → LAPI → Traefik bouncer (ban IPs)
- **CI/CD**: Git push → Tekton → kaniko build → Harbor → ArgoCD deploy
- **Auth flow**: Browser → Traefik → Authelia forward-auth → App
- **OIDC clients**: ArgoCD, Gitea, Grafana, Harbor, Coder

</details>

---

## Components

| Component | Namespace | URL | Purpose |
|---|---|---|---|
| 🏠 **Homepage** | homepage | portal.your.domain.com | Unified dashboard (9 tabs) |
| 🔄 ArgoCD | argocd | argocd.your.domain.com | GitOps engine |
| 🔀 Traefik | traefik-system | traefik.your.domain.com | Ingress + TLS termination |
| 🔐 Authelia | authelia | authelia.your.domain.com | SSO / forward-auth / OIDC provider |
| 💻 **Coder** | coder | realcoder.your.domain.com | Remote development environments (OIDC) |
| 🛡️ CrowdSec | crowdsec | — | Threat detection + IP banning |
| 🦅 **Falco** | falco | falco.your.domain.com | Container runtime security (eBPF) |
| 🔒 Sealed Secrets | kube-system | — | Encrypted secrets in Git |
| 📊 Prometheus + Grafana | monitoring | grafana.your.domain.com | Metrics + dashboards |
| 📋 Loki + Fluent Bit | logging | — | Log aggregation |
| 🐙 Gitea | gitea | git.your.domain.com | Self-hosted Git |
| ⚓ Harbor | harbor | allaboard.your.domain.com | Container registry |
| 📡 Uptime Kuma | uptime-kuma | uptime.your.domain.com | Availability monitoring |
| 📝 Hugo Blog | hugo-blog | blog.your.domain.com | Static site |
| 📤 **Pingvin Share** | sharing | pony.up.kubernative.io | Self-hosted file sharing |
| ⚙️ Tekton Pipelines | tekton-pipelines | — | CI/CD pipeline engine |
| 🖥️ Tekton Dashboard | tekton-pipelines | tekton.your.domain.com | Pipeline UI (devops + admins) |
| 🧪 Sample App | sample-app | sample-app.your.domain.com | Demo Go app with Prometheus metrics |

---

## Repository Structure

```
.
├── installer.sh                  # Bootstraps K3s + ArgoCD
├── .env                          # Active environment config (not committed)
├── .env.example                  # Config template
├── Vagrantfile                   # Local dev VM (VirtualBox or libvirt)
├── vagrant/
│   ├── provision.sh              # Full VM provisioner (idempotent)
│   ├── cluster-issuer-ca.yaml    # cert-manager ClusterIssuer for self-signed CA
│   └── trust-ca.sh               # Install the Vagrant CA on your host machine
├── argocd/
│   ├── applications/             # ArgoCD Application manifests
│   │   ├── core/                 # Traefik, Sealed Secrets
│   │   ├── monitoring/           # Prometheus, Loki, Uptime Kuma
│   │   ├── apps/                 # Gitea, Harbor, Jupyter, Hugo
│   │   └── security/             # Authelia, CrowdSec
│   └── projects/                 # ArgoCD RBAC projects
├── charts/                       # Helm values files (one per app)
├── tekton/
│   ├── pipelines/                # Pipeline definitions
│   ├── tasks/                    # Custom Task definitions (kaniko)
│   ├── serviceaccounts/          # Pipeline ServiceAccount
│   ├── workspaces/               # PVC for pipeline workspace
│   └── pipelineruns/             # Example PipelineRun (commented — manual trigger)
├── apps/
│   └── sample-app/               # Demo Go app with Prometheus metrics
│       ├── main.go               # HTTP server (/  + /metrics)
│       ├── Dockerfile            # Multi-stage build (golang → alpine, non-root)
│       └── k8s/                  # Deployment, Service, Ingress, ServiceMonitor
├── config/
│   └── organizations.yaml        # Groups and project definitions
├── k8s-manifests/
│   ├── authelia-middleware.yaml  # Traefik ForwardAuth Middleware CRD
│   ├── tekton-dashboard/         # Vendored Tekton Dashboard release + Ingress
│   ├── tekton-rbac.yaml          # Pipeline ServiceAccount RBAC
│   ├── grafana-dashboard-sample-app.yaml  # Grafana dashboard (auto-loaded)
│   └── grafana-dashboard-tekton.yaml      # Grafana dashboard (auto-loaded)
├── scripts/
│   ├── generate-authelia-users.sh  # Regenerate authelia-users.yml (all users, one password)
│   ├── change-passwords.sh         # Change password for one or all users
│   └── test-sso.sh
├── authelia-users.yml            # Authelia user database
└── docs/
    ├── authelia-totp.md          # Pre-registered TOTP URIs for all test users
    └── gitea-authelia-sso.md
```

---

## Authentication (Authelia SSO)

All ingresses are protected by Authelia forward-auth via the `authelia-forwardauth@kubernetescrd` Traefik middleware.

### Groups

Group names follow AD-mappable naming (`<project>_dev`, `<project>_test`, `<project>_prd`):

| Project | Groups |
|---|---|
| homelab | homelab_dev, homelab_test, homelab_prd |
| webapp | webapp_dev, webapp_test, webapp_prd |
| devops | devops_dev, devops_test, devops_prd |
| platform | platform_dev, platform_test, platform_prd |
| cross-cutting | admins, viewers |

### Access Policy

| Group type | Policy | Scope |
|---|---|---|
| admins, viewers | one_factor | all `*.your.domain.com` |
| devops_dev, devops_test | one_factor | ArgoCD, Tekton, Gitea, Harbor, Grafana |
| devops_prd | two_factor | ArgoCD, Tekton, Gitea, Harbor, Grafana |
| platform_*, homelab_* | one_factor / two_factor | Grafana, Gitea, sample-app, general apps |
| webapp_* | one_factor / two_factor | Gitea, Harbor, sample-app |
| `*_prd` (any) | two_factor | their project's domains |

### 2FA

- **Method**: TOTP only (WebAuthn disabled)
- **Issuer**: `kubernative.io`
- **Email fully disabled** — no SMTP configured, no email sent at any point:
  - Password reset: disabled
  - Email verification: disabled
  - Notifier: filesystem only (`/tmp/authelia-notifications.log`)

**TOTP is pre-registered for all users via CLI** — users are dropped directly to the TOTP prompt on first login, no identity-verification one-time-code step required.

To re-register a user's TOTP (e.g. after they lose their authenticator):
```bash
POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
kubectl exec -n authelia $POD -- \
  authelia storage user totp generate <username> --config /configuration.yaml --force
```
This prints an `otpauth://` URI. Scan it with any authenticator app (Google Authenticator, Authy, etc.) or use `qrencode -t UTF8 '<uri>'` to render a QR code in the terminal.

See `docs/authelia-totp.md` for all pre-registered TOTP URIs.

If Authelia ever writes a notification (e.g. a re-enrollment link), read it from the pod:
```bash
kubectl exec -n authelia daemonset/authelia -- cat /tmp/authelia-notifications.log
```

### Test Users

All test users share the default password `Homelab2024!`. See `authelia-users.yml` for the full list.

| User | Display name | Groups |
|------|-------------|--------|
| smii | System Administrator | admins, homelab_prd, webapp_prd, devops_prd, platform_prd |
| alice | Alice Dev | homelab_dev |
| bob | Bob QA | homelab_test |
| carol | Carol Ops | homelab_prd |
| dave | Dave WebDev | webapp_dev |
| eve | Eve WebQA | webapp_test |
| frank | Frank WebOps | webapp_prd |
| grace | Grace DevopsEng | devops_dev |
| henry | Henry DevopsQA | devops_test |
| ivan | Ivan DevopsOps | devops_prd |
| judy | Judy Platform | platform_dev |
| karl | Karl PlatformQA | platform_test |
| linda | Linda PlatformOps | platform_prd |
| viewer | Read Only User | viewers |

### Changing Default Passwords

Use `scripts/change-passwords.sh` to update passwords. The script generates a fresh argon2id hash, patches `authelia-users.yml`, re-applies the K8s secret, and restarts Authelia — all in one step.

```bash
# Interactive (prompts for username + password)
./scripts/change-passwords.sh

# Change a single user non-interactively
./scripts/change-passwords.sh smii 'MyNewSecurePass!'

# Change ALL users to the same password
./scripts/change-passwords.sh --all 'MyNewSecurePass!'
```

After changing a password, TOTP secrets remain valid — the user can still log in with their existing authenticator. If you also need to re-enroll their TOTP (e.g. they lost their phone):

```bash
POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
kubectl exec -n authelia $POD -- \
  authelia storage user totp generate <username> --config /configuration.yaml --force
```

To regenerate `authelia-users.yml` from scratch with a new default hash (all users same password):
```bash
./scripts/generate-authelia-users.sh
```

---

## Deployment

### First-time setup

```bash
# 1. Apply the Authelia Traefik middleware CRD
kubectl apply -f k8s-manifests/authelia-middleware.yaml

# 2. Push users file as a K8s secret
./scripts/generate-authelia-users.sh

# 3. ArgoCD will auto-sync remaining apps (if auto-sync enabled)
# Or trigger manually:
argocd app sync authelia
```

### Adding a new application

1. Create `argocd/applications/<category>/myapp.yaml`
2. Create `charts/myapp/values.yaml` with ingress annotation:
   ```yaml
   ingress:
     annotations:
       traefik.ingress.kubernetes.io/router.middlewares: "authelia-forwardauth@kubernetescrd"
   ```
3. Commit — ArgoCD deploys automatically.

### Modifying an existing app

Edit the relevant `charts/<app>/values.yaml` and commit. ArgoCD picks up the change.

---

## ArgoCD

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# CLI login
argocd login argocd.your.domain.com

# Sync all apps
argocd app sync --all

# Check status
argocd app list
```

---

## CI/CD with Tekton

### Overview

Tekton Pipelines runs inside the cluster. The Dashboard is at `https://tekton.your.domain.com` — access requires `devops_*` or `admins` group membership (Authelia forward-auth, 2FA for `devops_prd`).

### Sample app pipeline

The included pipeline clones this repo from Gitea, builds the sample app with **kaniko** (no Docker daemon needed on K3s), and pushes to Harbor:

```
git-clone → kaniko build → push to allaboard.your.domain.com/library/sample-app:latest
```

ArgoCD then deploys the updated image from `apps/sample-app/k8s/`.

### Before first run — create Harbor credentials

```bash
kubectl create secret docker-registry harbor-credentials \
  --docker-server=allaboard.your.domain.com \
  --docker-username=<harbor-user> \
  --docker-password=<harbor-password> \
  -n tekton-pipelines
```

### Trigger a build

```bash
# Uncomment the PipelineRun and apply
kubectl apply -f tekton/pipelineruns/sample-app-run.yaml

# Watch progress
kubectl get pipelineruns -n tekton-pipelines -w

# Stream logs for a run
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<run-name> --all-containers -f
```

### Grafana dashboards

Two dashboards are pre-loaded via ConfigMap (label `grafana_dashboard: "1"`, picked up by the Grafana sidecar automatically):

| Dashboard | File | Panels |
|-----------|------|--------|
| Sample App | `k8s-manifests/grafana-dashboard-sample-app.yaml` | Request rate, error rate, p50/p95/p99 latency, active requests |
| Tekton Pipelines | `k8s-manifests/grafana-dashboard-tekton.yaml` | Run count, success rate, status breakdown, duration percentiles |

Grafana roles are assigned from Authelia groups on every login: `admins` → GrafanaAdmin, `devops_*` → Editor, others → Viewer.

---

## Sync Waves

Apps deploy in dependency order:

| Wave | Apps |
|---|---|
| 0 | Sealed Secrets |
| 1 | Traefik, CrowdSec |
| 2 | Authelia, Tekton Pipelines |
| 3 | Gitea, Harbor, Prometheus stack, Tekton Dashboard |
| 4 | Jupyter, Uptime Kuma, Hugo Blog, Sample App, Tekton resources |

---

## Troubleshooting

```bash
# Check all pods
kubectl get pods -A

# Authelia logs
kubectl logs -n authelia daemonset/authelia --tail=50

# ArgoCD sync errors
kubectl describe application <name> -n argocd

# Validate SSO
./scripts/test-sso.sh

# Traefik ingress routes
kubectl get ingressroutes -A

# Check cert-manager certificate status
kubectl get certificates -A

# Check ACME challenge solver ingresses (should show CLASS: traefik)
kubectl get ingresses -A

# Re-register TOTP for a user
POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
kubectl exec -n authelia $POD -- \
  authelia storage user totp generate <username> --config /configuration.yaml --force
```

### Tekton

```bash
# Check all Tekton pods
kubectl get pods -n tekton-pipelines

# List pipeline runs and their status
kubectl get pipelineruns -n tekton-pipelines

# Stream logs for a running pipeline
kubectl logs -n tekton-pipelines -l tekton.dev/pipelineRun=<run-name> --all-containers -f

# Check Tekton Dashboard ingress + cert
kubectl get ingress,certificate -n tekton-pipelines

# Tekton Dashboard is SSO-protected — only devops_* and admins groups can access it
# If you get a 403 from Authelia, check the user's group membership
```

### Known issues / resolved

| Issue | Root cause | Fix |
|---|---|---|
| Traefik serving self-signed cert instead of Let's Encrypt | `ClusterIssuer` used deprecated `class: traefik`; solver ingresses got `CLASS: <none>` and Traefik ignored them | Changed to `ingressClassName: traefik` in `installer/cluster-issuer-le-prod.yaml` |
| Authelia session lost on pod restart | `persistence.enabled: false` — SQLite at `/config/db.sqlite3` was in ephemeral storage | `persistence.enabled: true` — 100Mi PVC mounted at `/config/` |
| Notification log not found at `/tmp/authelia-notifications.log` | YAML quoting `filename: '/tmp/...'` rendered as `''/tmp/...''` (literal quote chars in path) | Removed quotes: `filename: /tmp/authelia-notifications.log` |
| All users presented with one-time-code instead of TOTP prompt | Authelia v4.38+ requires elevated session identity verification before 2FA registration | Pre-registered all TOTP secrets via `authelia storage user totp generate` CLI |

---

## Test Environment

- Hardware: AMD 5700, 32 GB RAM, 500 GB SSD
- OS: Ubuntu
- Router: ASUSWRT with dnsmasq
- Public domain: `kubernative.io` (TransIP DNS, used by cert-manager DNS01)
- Local domain: `*.your.domain.com` → `192.168.1.56`

```bash
# dnsmasq entry (/jffs/configs/dnsmasq.conf.add on ASUSWRT):
address=/.your.domain.com/192.168.1.56
```
