#!/usr/bin/env bash
# =============================================================================
# k3sdevlab Vagrant Provisioner
# =============================================================================
# Bootstraps a self-contained K3s + ArgoCD homelab inside a Vagrant VM.
#
# What happens here (in order):
#  1. Install system packages
#  2. Copy the synced repo to a work dir and apply vagrant-specific patches:
#       - Domains: rtm.kubernative.io → <VM_IP>.nip.io
#       - TLS issuer: letsencrypt-prod → vagrant-ca
#       - Git remote: github.com → git-daemon running locally in the VM
#       - lite profile: removes Harbor, CrowdSec, Loki, Fluent-Bit
#  3. Create a local bare git repo served by git-daemon on port 9418.
#     ArgoCD GitOps pulls from git://<VM_IP>/homelab.git — no GitHub needed.
#  4. Install K3s, Helm, cert-manager (before ArgoCD apps start syncing)
#  5. Generate a self-signed CA and create the cert-manager ClusterIssuer
#  6. Write .env.vagrant and run installer.sh (installs ArgoCD, deploys apps)
#  7. Wait for Authelia and register TOTP for all test users
#  8. Print the access summary
#
# Re-run with: vagrant provision
# =============================================================================
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
VM_IP="${VM_IP:-192.168.56.100}"
VAGRANT_PROFILE="${VAGRANT_PROFILE:-lite}"
VAGRANT_DOMAIN="${VM_IP}.nip.io"
SRC="/homelab"
WORK_DIR="/opt/homelab"
LOCAL_GIT_DIR="/srv/git"
LOCAL_GIT_REPO="${LOCAL_GIT_DIR}/homelab.git"
CA_DIR="/etc/ssl/vagrant-ca"

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo "▶  $*"; }
ok()    { echo "✓  $*"; }
warn()  { echo "⚠  $*"; }
die()   { echo "✗  $*" >&2; exit 1; }
hr()    { echo "────────────────────────────────────────────────────────────────"; }

hr
info "k3sdevlab Vagrant Provisioner"
info "Profile : ${VAGRANT_PROFILE}   VM IP: ${VM_IP}   Domain: ${VAGRANT_DOMAIN}"
hr

# =============================================================================
# 1. SYSTEM PACKAGES
# =============================================================================
info "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null
apt-get install -y --no-install-recommends \
  git curl jq openssl ca-certificates \
  gettext-base apache2-utils 2>/dev/null
ok "System packages ready."

# =============================================================================
# 2. PREPARE PATCHED WORK DIRECTORY
# =============================================================================
info "Preparing work directory ${WORK_DIR}..."
rm -rf "${WORK_DIR}"
cp -r "${SRC}" "${WORK_DIR}"
cd "${WORK_DIR}"

# Disable update-configs.sh so installer.sh doesn't regenerate values from
# templates and accidentally re-introduce production domains or overwrite
# the vagrant-specific cert issuer name we set below.
chmod -x scripts/update-configs.sh 2>/dev/null || true

# ── Domain substitution ───────────────────────────────────────────────────────
info "Patching: rtm.kubernative.io → ${VAGRANT_DOMAIN}"
find charts/ argocd/ installer/ -name "*.yaml" -print0 \
  | xargs -0 sed -i "s/rtm\.kubernative\.io/${VAGRANT_DOMAIN}/g"

# Also patch the bare kubernative.io where it appears (TOTP issuer, OIDC, etc.)
find charts/ -name "*.yaml" -print0 \
  | xargs -0 sed -i \
      -e "s|issuer: 'kubernative\.io'|issuer: '${VAGRANT_DOMAIN}'|g" \
      -e "s|issuer: kubernative\.io|issuer: ${VAGRANT_DOMAIN}|g"

# ── TLS issuer ────────────────────────────────────────────────────────────────
info "Patching: letsencrypt-prod → vagrant-ca"
find charts/ argocd/ installer/ -name "*.yaml" -print0 \
  | xargs -0 sed -i "s/letsencrypt-prod/vagrant-ca/g"

# ── Git remote URLs ───────────────────────────────────────────────────────────
info "Patching: github.com → git://${VM_IP}/homelab.git"
find argocd/ -name "*.yaml" -print0 \
  | xargs -0 sed -i \
      -e "s|https://github\.com/smii/k3sdevlab|git://${VM_IP}/homelab.git|g" \
      -e "s|git@github\.com:smii/k3sdevlab\.git|git://${VM_IP}/homelab.git|g"

# The argocd/config/repositories.yaml is applied by installer.sh via envsubst.
# Since it hardcodes the URL rather than using $GITHUB_REPO, patch it directly.
sed -i "s|url: git@github\.com:smii/k3sdevlab\.git|url: git://${VM_IP}/homelab.git|g" \
  argocd/config/repositories.yaml 2>/dev/null || true

# ── Lite profile: remove heavyweight apps ────────────────────────────────────
if [ "${VAGRANT_PROFILE}" = "lite" ]; then
  info "Lite profile: removing Harbor, CrowdSec, Loki, Fluent-Bit"
  rm -f argocd/applications/apps/harbor.yaml
  rm -f argocd/applications/security/crowdsec.yaml
  rm -f argocd/applications/monitoring/loki-stack.yaml
  rm -f argocd/applications/monitoring/fluent-bit.yaml
fi

ok "Work directory patched."

# =============================================================================
# 3. LOCAL GIT REPO + GIT-DAEMON
# =============================================================================
info "Creating local git repo at ${LOCAL_GIT_REPO}..."
mkdir -p "${LOCAL_GIT_DIR}"

# Init a regular repo in WORK_DIR and commit all patches
git -C "${WORK_DIR}" init -b develop 2>/dev/null
git -C "${WORK_DIR}" config user.email "vagrant@local.dev"
git -C "${WORK_DIR}" config user.name  "Vagrant Provisioner"
git -C "${WORK_DIR}" add -A
git -C "${WORK_DIR}" commit -q -m \
  "chore: vagrant provisioning patches — ${VAGRANT_DOMAIN} (profile: ${VAGRANT_PROFILE})"

# Create a bare clone for git-daemon to serve (remove stale clone on re-provision)
rm -rf "${LOCAL_GIT_REPO}"
git clone --bare "${WORK_DIR}" "${LOCAL_GIT_REPO}" 2>/dev/null
# The magic file that allows git-daemon to export this repo
touch "${LOCAL_GIT_REPO}/git-daemon-export-ok"
ok "Bare git repo created."

info "Starting git-daemon (port 9418)..."
cat > /etc/systemd/system/git-daemon.service << EOF
[Unit]
Description=Git Daemon — k3sdevlab local repo
After=network.target

[Service]
ExecStart=/usr/bin/git daemon \\
  --reuseaddr \\
  --verbose \\
  --base-path=${LOCAL_GIT_DIR} \\
  --export-all \\
  ${LOCAL_GIT_DIR}
Restart=on-failure
User=nobody

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now git-daemon
ok "git-daemon running on port 9418."

# =============================================================================
# 4. K3S
# =============================================================================
info "Installing K3s (Traefik disabled — Helm manages it via ArgoCD)..."
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_EXEC="server --disable=traefik" sh -
else
  warn "K3s already installed — skipping."
fi

info "Waiting for K3s node to become Ready..."
for i in $(seq 1 60); do
  kubectl get nodes &>/dev/null 2>&1 && break
  sleep 2
done
kubectl wait --for=condition=Ready node --all --timeout=120s
ok "K3s ready: $(kubectl get nodes --no-headers | awk '{print $1, $2}')"

# Expose kubeconfig for root and the vagrant user
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
if id vagrant &>/dev/null; then
  mkdir -p /home/vagrant/.kube
  cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
  chown vagrant:vagrant /home/vagrant/.kube/config
  echo 'export KUBECONFIG=/home/vagrant/.kube/config' >> /home/vagrant/.bashrc
fi

# =============================================================================
# 5. HELM
# =============================================================================
info "Installing Helm..."
if ! command -v helm &>/dev/null; then
  curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | bash -s -- --no-sudo
else
  warn "Helm already installed — skipping."
fi
ok "Helm $(helm version --short --client) installed."

# =============================================================================
# 6. CERT-MANAGER + SELF-SIGNED CA
# cert-manager must be running BEFORE ArgoCD deploys apps that request certs.
# =============================================================================
info "Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null
helm repo update jetstack 2>/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 5m
ok "cert-manager ready."

# Generate the local CA
info "Generating self-signed CA..."
mkdir -p "${CA_DIR}"
openssl genrsa -out "${CA_DIR}/ca.key" 4096 2>/dev/null
openssl req -new -x509 -days 3650 \
  -key  "${CA_DIR}/ca.key" \
  -out  "${CA_DIR}/ca.crt" \
  -subj "/CN=k3sdevlab Vagrant CA/O=Homelab Dev/C=NL" 2>/dev/null
chmod 644 "${CA_DIR}/ca.crt"
chmod 600 "${CA_DIR}/ca.key"

# Create a TLS secret in cert-manager's namespace so the ClusterIssuer can use it
kubectl create secret tls vagrant-ca-keypair \
  --cert="${CA_DIR}/ca.crt" \
  --key="${CA_DIR}/ca.key" \
  --namespace cert-manager \
  --dry-run=client -o yaml | kubectl apply -f -

# Deploy the cert-manager ClusterIssuer
kubectl apply -f "${WORK_DIR}/vagrant/cluster-issuer-ca.yaml"
kubectl wait --for=condition=Ready clusterissuer/vagrant-ca --timeout=60s
ok "ClusterIssuer 'vagrant-ca' ready."

# =============================================================================
# 7. .ENV.VAGRANT + RUN INSTALLER
# =============================================================================
info "Writing .env.vagrant..."
cat > "${WORK_DIR}/.env.vagrant" << EOF
# ============================================================
# k3sdevlab Vagrant Environment
# Auto-generated by vagrant/provision.sh — do not edit manually
# ============================================================
# Domain  : ${VAGRANT_DOMAIN}  (nip.io — resolves without /etc/hosts)
# TLS     : Self-signed CA at ${CA_DIR}/ca.crt
# Git     : git-daemon at git://${VM_IP}/homelab.git (port 9418)
# Profile : ${VAGRANT_PROFILE}
# ============================================================

PUBLIC_DOMAIN=nip.io
LOCAL_DOMAIN=${VAGRANT_DOMAIN}
LETSENCRYPT_EMAIL=vagrant@local.dev

# ArgoCD pulls from the local git-daemon, not GitHub
GITHUB_REPO=git://${VM_IP}/homelab.git
GIT_TARGET_REVISION=HEAD
GIT_APPS_PATH=argocd/applications
GIT_PROJECTS_PATH=argocd/projects

# ArgoCD
ARGOCD_HOST=argocd.${VAGRANT_DOMAIN}
ARGOCD_NAMESPACE=argocd
ARGOCD_VERSION=5.46.8
ARGOCD_ADMIN_PASSWORD=Homelab2024!
ARGOCD_SERVER_INSECURE=true
ARGOCD_INGRESS_ENABLED=true
ARGOCD_INGRESS_CLASS=traefik
ARGOCD_TLS_ENABLED=true

# Sync policy
AUTO_SYNC_ENABLED=true
AUTO_PRUNE_ENABLED=true
SELF_HEAL_ENABLED=true
SYNC_RETRY_LIMIT=3

# ArgoCD projects
APPS_PROJECT=homelab
CORE_PROJECT=core-infrastructure
MONITORING_PROJECT=monitoring
SECURITY_PROJECT=security
APPLICATIONS_PROJECT=applications

# Authelia SSO
AUTHELIA_ADMIN_USERNAME=smii
AUTHELIA_ADMIN_PASSWORD=Homelab2024!
AUTHELIA_ADMIN_EMAIL=smii@${VAGRANT_DOMAIN}
AUTHELIA_DOMAIN=${VAGRANT_DOMAIN}
AUTHELIA_HOST=authelia.${VAGRANT_DOMAIN}

# Secrets auto-generated by installer.sh
AUTHELIA_JWT_SECRET=
AUTHELIA_SESSION_SECRET=
AUTHELIA_STORAGE_ENCRYPTION_KEY=
AUTHELIA_OIDC_HMAC_SECRET=
AUTHELIA_OIDC_GITEA_CLIENT_SECRET=

# Skip Gitea org setup — Gitea may not be ready when installer runs
ORG_STRUCTURE_ENABLED=false
ORG_CONFIG_FILE=config/organizations.yaml
AUTO_SETUP_ORGS=false
AUTO_SETUP_AUTHELIA_USERS=false

DRY_RUN=false
DEBUG_MODE=false
EOF
ok ".env.vagrant written."

# =============================================================================
# 7b. PRE-CREATE AUTHELIA NAMESPACE + SECRETS
# The Authelia Helm chart uses secret.existingSecret: 'authelia', which means
# the secret MUST exist before ArgoCD syncs the Authelia app (prune:true would
# delete a helm-managed secret on the next sync anyway).
# The authelia-users secret must also be in the 'authelia' namespace — not the
# 'security' namespace that installer.sh's create_authelia_users_secret targets.
# =============================================================================
info "Pre-creating authelia namespace and required secrets..."

kubectl create namespace authelia --dry-run=client -o yaml | kubectl apply -f -

# Generate fresh random secrets for this Vagrant instance
kubectl create secret generic authelia \
  --from-literal="storage.encryption.key=$(openssl rand -base64 64 | tr -d '\n')" \
  --from-literal="session.encryption.key=$(openssl rand -base64 64 | tr -d '\n')" \
  --from-literal="identity_providers.oidc.hmac.key=$(openssl rand -hex 64)" \
  --from-literal="identity_validation.reset_password.jwt.hmac.key=$(openssl rand -hex 64)" \
  -n authelia \
  --dry-run=client -o yaml | kubectl apply -f -

# Annotate with resource-policy=keep so ArgoCD/Helm never prunes this secret.
# Intentionally NO argocd.argoproj.io/tracking-id — keeps it out of ArgoCD's
# managed resource list so prune:true won't delete it.
kubectl annotate secret authelia -n authelia \
  'helm.sh/resource-policy=keep' --overwrite

# Create the users file secret in the correct namespace (authelia, not security).
# The Authelia chart mounts this as /config/users.yml via the users.file.path setting.
kubectl create secret generic authelia-users \
  --from-file=users.yml="${WORK_DIR}/authelia-users.yml" \
  -n authelia \
  --dry-run=client -o yaml | kubectl apply -f -

ok "Authelia namespace and secrets ready."

info "Running installer.sh (installs ArgoCD and triggers GitOps sync)..."
info "This typically takes 5-10 minutes..."
cd "${WORK_DIR}"
./installer.sh .env.vagrant
ok "installer.sh complete."

# =============================================================================
# 8. WAIT FOR AUTHELIA + REGISTER TOTP
# =============================================================================
info "Waiting for Authelia pod to become Ready (up to 5 min)..."
if kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=authelia \
  -n authelia --timeout=300s 2>/dev/null; then

  AUTHELIA_POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
  info "Registering TOTP for all test users (pod: ${AUTHELIA_POD})..."
  for user in smii alice bob carol dave eve frank grace henry ivan judy karl linda viewer; do
    result=$(kubectl exec -n authelia "${AUTHELIA_POD}" -- \
      authelia storage user totp generate "${user}" \
      --config /configuration.yaml --force 2>&1 || true)
    echo "  ${user}: $(echo "${result}" | grep -o 'secret=[A-Z2-7]*' | head -1 || echo 'see full output above')"
  done
  ok "TOTP registered for all users."
else
  warn "Authelia not ready yet — TOTP registration skipped."
  warn "Once Authelia is running, re-register with:"
  warn "  kubectl exec -n authelia \$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2) -- \\"
  warn "    authelia storage user totp generate smii --config /configuration.yaml --force"
fi

# =============================================================================
# 9. SUMMARY
# =============================================================================
ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "Homelab2024!")

HARBOR_LINE=""
if [ "${VAGRANT_PROFILE}" = "full" ]; then
  HARBOR_LINE="  Harbor     → https://notary.allaboard.${VAGRANT_DOMAIN}"
fi

cat << SUMMARY

$(hr)
  k3sdevlab Vagrant Environment Ready
$(hr)

  Profile : ${VAGRANT_PROFILE}
  VM IP   : ${VM_IP}
  Domain  : *.${VAGRANT_DOMAIN}

  SERVICES
  ────────
  ArgoCD     → https://argocd.${VAGRANT_DOMAIN}
  Authelia   → https://authelia.${VAGRANT_DOMAIN}
  Gitea      → https://git.${VAGRANT_DOMAIN}
  Grafana    → https://grafana.${VAGRANT_DOMAIN}
  Prometheus → https://prometheus.${VAGRANT_DOMAIN}
  Traefik    → https://traefik.${VAGRANT_DOMAIN}
  Uptime     → https://uptime.${VAGRANT_DOMAIN}
  Jupyter    → https://notebook.${VAGRANT_DOMAIN}
${HARBOR_LINE}

  CREDENTIALS
  ──────────
  All services    smii / Homelab2024!
  ArgoCD admin    admin / ${ARGOCD_PW}

  TLS — Self-signed CA (browser will warn once per app)
  To trust the CA permanently, run on your HOST machine:
    bash vagrant/trust-ca.sh

  CA certificate inside the VM: ${CA_DIR}/ca.crt

$(hr)
Note: ArgoCD is still syncing apps in the background.
  Wait ~10 minutes then check: https://argocd.${VAGRANT_DOMAIN}
  Username: admin    Password: ${ARGOCD_PW}
$(hr)

SUMMARY
