#!/usr/bin/env bash

# K3s + ArgoCD GitOps Installer
# This script installs K3s and ArgoCD, then lets ArgoCD handle all other applications
# Exit immediately if a command exits with a non-zero status,
# Exit if any command in a pipeline fails,
# Treat unset variables as an error.
set -euo pipefail

# --- CONFIGURATION FUNCTIONS ---

config_vars() {
  local ENV_FILE="$1"

  # Load environment file if it exists
  if [[ -f "$ENV_FILE" ]]; then
    echo "Loading configuration from ${ENV_FILE}..."
    while IFS='=' read -r key value; do
      if [[ $key =~ ^#.* ]] || [[ -z $key ]]; then
        continue
      fi
      value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//')
      export "$key=$value"
    done < "$ENV_FILE"
  else
    echo "❌ Error: Configuration file '${ENV_FILE}' not found. Exiting."
    exit 1
  fi

  # --- SET DEFAULTS & CHECK MANDATORY VARS ---
  : "${PUBLIC_DOMAIN:?Error: PUBLIC_DOMAIN not set in config file.}"
  : "${LOCAL_DOMAIN:?Error: LOCAL_DOMAIN not set in config file.}"
  : "${LETSENCRYPT_EMAIL:?Error: LETSENCRYPT_EMAIL not set in config file.}"

  # ArgoCD Configuration with defaults
  : "${ARGOCD_NAMESPACE:=argocd}"
  : "${ARGOCD_VERSION:=5.46.8}"
  : "${ARGOCD_ADMIN_PASSWORD:=}"
  : "${ARGOCD_SERVER_INSECURE:=true}"
  : "${ARGOCD_INGRESS_ENABLED:=true}"
  : "${ARGOCD_INGRESS_CLASS:=traefik}"
  : "${ARGOCD_TLS_ENABLED:=true}"
  
  # Git Repository Configuration
  : "${GITHUB_REPO:=https://github.com/smii/k3sdevlab}"
  : "${GIT_TARGET_REVISION:=HEAD}"
  : "${GIT_APPS_PATH:=argocd/applications}"
  : "${GIT_PROJECTS_PATH:=argocd/projects}"
  : "${GIT_USERNAME:=}"
  : "${GIT_TOKEN:=}"
  : "${GIT_SSH_PRIVATE_KEY_PATH:=}"
  
  # ArgoCD Sync Policy
  : "${AUTO_SYNC_ENABLED:=true}"
  : "${AUTO_PRUNE_ENABLED:=true}"
  : "${SELF_HEAL_ENABLED:=true}"
  : "${SYNC_RETRY_LIMIT:=3}"
  
  # Project Configuration
  : "${APPS_PROJECT:=homelab}"
  : "${CORE_PROJECT:=core-infrastructure}"
  : "${MONITORING_PROJECT:=monitoring}"
  : "${SECURITY_PROJECT:=security}"
  : "${APPLICATIONS_PROJECT:=applications}"
  
  # Organizational Structure Configuration
  : "${ORG_STRUCTURE_ENABLED:=true}"
  : "${ORG_CONFIG_FILE:=config/organizations.yaml}"
  : "${AUTO_SETUP_ORGS:=true}"
  : "${AUTO_SETUP_AUTHELIA_USERS:=true}"
  
  # Authelia Configuration
  : "${AUTHELIA_ADMIN_USERNAME:=admin}"
  : "${AUTHELIA_ADMIN_PASSWORD:=changeme}"
  : "${AUTHELIA_ADMIN_EMAIL:=admin@${LOCAL_DOMAIN}}"
  : "${AUTHELIA_DOMAIN:=${PUBLIC_DOMAIN}}"
  : "${AUTHELIA_HOST:=authelia.rtm.${PUBLIC_DOMAIN}}"
  
  # Authelia Secrets (will be auto-generated if empty)
  : "${AUTHELIA_JWT_SECRET:=}"
  : "${AUTHELIA_SESSION_SECRET:=}"
  : "${AUTHELIA_STORAGE_ENCRYPTION_KEY:=}"
  : "${AUTHELIA_OIDC_HMAC_SECRET:=}"
  : "${AUTHELIA_OIDC_GITEA_CLIENT_SECRET:=}"
  : "${AUTHELIA_OIDC_PRIVATE_KEY_PATH:=}"
  
  # System defaults
  : "${DRY_RUN:=false}"
  : "${DEBUG_MODE:=false}"
  
  # Set derived variables
  : "${ARGOCD_HOST:=argocd.${LOCAL_DOMAIN}}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "🚨 DRY-RUN MODE IS ENABLED. No changes will be made to the system or Kubernetes cluster. 🚨"
  fi
  
  # Generate Authelia secrets if not provided
  if [[ -z "${AUTHELIA_JWT_SECRET}" ]] || \
     [[ -z "${AUTHELIA_SESSION_SECRET}" ]] || \
     [[ -z "${AUTHELIA_STORAGE_ENCRYPTION_KEY}" ]] || \
     [[ -z "${AUTHELIA_OIDC_HMAC_SECRET}" ]] || \
     [[ -z "${AUTHELIA_OIDC_GITEA_CLIENT_SECRET}" ]]; then
    
    echo "🔐 Some Authelia secrets are missing. Generating..."
    if [[ -f "scripts/generate-authelia-secrets.sh" ]]; then
      source scripts/generate-authelia-secrets.sh
      generate_authelia_secrets > /dev/null
      echo "   Authelia secrets generated successfully"
    else
      echo "   ⚠️  Warning: scripts/generate-authelia-secrets.sh not found"
      echo "   Please set all AUTHELIA_*_SECRET variables in your .env file"
    fi
  fi
  
  echo "Configuration loaded successfully."
}

generate_configs() {
  echo "--- 📝 Generating Configuration Files ---"
  if [[ -x "scripts/update-configs.sh" ]]; then
    ./scripts/update-configs.sh "$1"
  else
    echo "⚠️  scripts/update-configs.sh not found or not executable."
  fi
}

# --- EXECUTION WRAPPER ---

# Executes a command unless DRY_RUN is enabled.
execute_command() {
    local cmd="$*"
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "DRY-RUN: $cmd"
    else
        echo "Executing: $cmd"
        eval "$cmd"
    fi
}

# --- K3S/KUBERNETES FUNCTIONS ---

install_k3s() {
  echo "--- 🛠️  [1/6] K3s Installation Check ---"
  if ! command -v k3s &>/dev/null; then
    echo "k3s not found. Installing now..."
    # Disable Traefik since ArgoCD will manage it
    execute_command "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server --disable traefik\" sh -"
  else
    echo "✅ k3s already installed."
  fi
}

setup_kubeconfig() {
  echo "--- 🔑 [2/6] Setting up Kubeconfig ---"
  if ! command -v kubectl &>/dev/null; then
    echo "kubectl not found, installing..."
    execute_command "curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    execute_command "chmod +x kubectl"
    execute_command "sudo mv kubectl /usr/local/bin/"
  fi
  
  execute_command "mkdir -p ~/.kube"
  if [[ "${DRY_RUN}" == "false" ]]; then
      sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config || { echo "❌ Failed to copy k3s.yaml. K3s may not be fully installed."; exit 1; }
      sudo chown "$(id -u):$(id -g)" ~/.kube/config
  else
      echo "DRY-RUN: sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config"
      echo "DRY-RUN: sudo chown \$(id -u):\$(id -g) ~/.kube/config"
  fi
  echo "✅ Kubeconfig setup complete."
}

wait_for_k3s() {
  echo "--- ⏳ Waiting for k3s readiness ---"
  if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY-RUN: Skipping blocking wait for k3s."
      return 0
  fi

  local timeout=60
  for i in $(seq 1 $timeout); do
    if kubectl get nodes &>/dev/null; then
      echo "✅ k3s is ready after $i seconds."
      kubectl get nodes
      return 0
    fi
    echo "Waiting for kubectl access... ($i/$timeout)"
    sleep 1
  done
  echo "❌ Error: k3s not ready after $timeout seconds."
  exit 1
}

install_helm() {
  echo "--- 📦 Installing Helm (for ArgoCD installation) ---"
  if ! command -v helm &>/dev/null; then
    echo "Helm not found, installing..."
    execute_command "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  else
    echo "✅ Helm already installed."
  fi
}

install_argocd_cli() {
  echo "--- 📱 Installing ArgoCD CLI ---"
  if ! command -v argocd &>/dev/null; then
    echo "ArgoCD CLI not found, installing..."
    execute_command "curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
    execute_command "chmod +x argocd-linux-amd64"
    execute_command "sudo mv argocd-linux-amd64 /usr/local/bin/argocd"
  else
    echo "✅ ArgoCD CLI already installed."
  fi
}

install_argocd() {
  echo "--- 🚀 [3/6] Installing ArgoCD ---"
  
  # Create ArgoCD namespace
  execute_command "kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -"
  
  # Add ArgoCD Helm repository
  execute_command "helm repo add argo https://argoproj.github.io/argo-helm"
  execute_command "helm repo update"
  
  # Create repository secret if Git credentials are provided
  if [[ -n "${GIT_USERNAME}" && -n "${GIT_TOKEN}" ]]; then
    echo "Creating Git repository secret for private repository access..."
    execute_command "kubectl create secret generic git-repo-secret \\
      --from-literal=username='${GIT_USERNAME}' \\
      --from-literal=password='${GIT_TOKEN}' \\
      --namespace=${ARGOCD_NAMESPACE} \\
      --dry-run=client -o yaml | kubectl apply -f -"
  fi
  
  # Create SSH key secret if SSH private key is provided
  if [[ -n "${GIT_SSH_PRIVATE_KEY_PATH}" && -f "${GIT_SSH_PRIVATE_KEY_PATH}" ]]; then
    echo "Creating SSH key secret for Git repository access..."
    execute_command "kubectl create secret generic git-ssh-secret \\
      --from-file=sshPrivateKey='${GIT_SSH_PRIVATE_KEY_PATH}' \\
      --namespace=${ARGOCD_NAMESPACE} \\
      --dry-run=client -o yaml | kubectl apply -f -"
  fi
  
  # Prepare ArgoCD installation command
  local install_cmd="helm upgrade --install argocd argo/argo-cd \\
    --namespace ${ARGOCD_NAMESPACE} \\
    --version ${ARGOCD_VERSION} \\
    --set server.ingress.enabled=${ARGOCD_INGRESS_ENABLED} \\
    --set server.ingress.ingressClassName=${ARGOCD_INGRESS_CLASS} \\
    --set server.ingress.hosts[0]='${ARGOCD_HOST}' \\
    --set server.insecure=${ARGOCD_SERVER_INSECURE}"
  
  # Add TLS configuration if enabled
  if [[ "${ARGOCD_TLS_ENABLED}" == "true" ]]; then
    install_cmd+=" --set server.ingress.tls[0].secretName='${ARGOCD_HOST}-tls' \\
    --set server.ingress.tls[0].hosts[0]='${ARGOCD_HOST}'"
  fi
  
  # Add custom admin password if provided
  if [[ -n "${ARGOCD_ADMIN_PASSWORD}" ]]; then
    install_cmd+=" --set configs.secret.argocdServerAdminPassword='$(htpasswd -bnBC 10 admin '${ARGOCD_ADMIN_PASSWORD}' | cut -d: -f2)'"
  fi
  
  # Check for custom values file
  local argocd_values_file="charts/argocd/argocd-values.yaml"
  if [[ -f "$argocd_values_file" ]]; then
    echo "Using custom ArgoCD values file: $argocd_values_file"
    install_cmd+=" --values ${argocd_values_file}"
  fi
  
  # Add repository configuration using proper format
  install_cmd+=" --set-json 'configs.repositories.homelab-repo={\"url\":\"${GITHUB_REPO}\",\"type\":\"git\",\"name\":\"homelab-repo\"}'"
  
  # Enable debug mode if requested
  if [[ "${DEBUG_MODE}" == "true" ]]; then
    install_cmd+=" --set server.extraArgs[0]='--log-level=debug' \\
    --set controller.extraArgs[0]='--log-level=debug'"
  fi
  
  # Execute installation
  install_cmd+=" --wait --timeout=10m"
  execute_command "$install_cmd"
  
  echo "✅ ArgoCD installation complete."
}

wait_for_argocd() {
  echo "--- ⏳ Waiting for ArgoCD to be ready ---"
  if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY-RUN: Skipping blocking wait for ArgoCD."
      return 0
  fi

  local timeout=300  # 5 minutes
  echo "Waiting for ArgoCD server to be ready..."
  if ! kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n ${ARGOCD_NAMESPACE} --timeout=${timeout}s; then
    echo "❌ ArgoCD server not ready after ${timeout} seconds."
    echo "Checking ArgoCD pods status:"
    kubectl get pods -n ${ARGOCD_NAMESPACE}
    exit 1
  fi
  echo "✅ ArgoCD is ready."
}

configure_argocd_repositories() {
  echo "--- 🔧 Configuring ArgoCD Repository Access ---"
  if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY-RUN: Skipping ArgoCD repository configuration."
      return 0
  fi

  # Wait a bit for ArgoCD to be fully ready
  sleep 10
  
  # Configure repository access using kubectl
  if [[ -f "argocd/config/repositories.yaml" ]]; then
    execute_command "GITHUB_REPO='${GITHUB_REPO}' envsubst < argocd/config/repositories.yaml | kubectl apply -f -"
  fi
  
  echo "✅ ArgoCD repository configuration complete."
}

deploy_argocd_projects() {
  echo "--- 📋 [4/6] Deploying ArgoCD Projects ---"
  
  if [[ -d "argocd/projects" ]]; then
    execute_command "kubectl apply -f argocd/projects/"
    echo "✅ ArgoCD projects deployed."
  else
    echo "⚠️  ArgoCD projects directory not found. Skipping project deployment."
  fi
}

deploy_bootstrap_application() {
  echo "--- 🌱 [5/6] Deploying Bootstrap Application (App of Apps) ---"
  
  # Deploy the bootstrap application that will manage all other applications
  if [[ -f "argocd/bootstrap/homelab-root.yaml" ]]; then
    # Update the repository URL and other variables in the bootstrap app
    local bootstrap_cmd="GITHUB_REPO='${GITHUB_REPO}' \\
      GIT_TARGET_REVISION='${GIT_TARGET_REVISION}' \\
      GIT_APPS_PATH='${GIT_APPS_PATH}' \\
      APPS_PROJECT='${APPS_PROJECT}' \\
      AUTO_SYNC_ENABLED='${AUTO_SYNC_ENABLED}' \\
      AUTO_PRUNE_ENABLED='${AUTO_PRUNE_ENABLED}' \\
      SELF_HEAL_ENABLED='${SELF_HEAL_ENABLED}' \\
      envsubst < argocd/bootstrap/homelab-root.yaml | kubectl apply -f -"
    execute_command "$bootstrap_cmd"
    echo "✅ Bootstrap application deployed. ArgoCD will now manage all other applications."
  else
    echo "⚠️  Bootstrap application not found. Deploying individual applications..."
    if [[ -d "argocd/applications" ]]; then
      execute_command "kubectl apply -f argocd/applications/ --recursive"
      echo "✅ Individual ArgoCD applications deployed."
    else
      echo "❌ No ArgoCD applications found. Manual configuration required."
    fi
  fi
}

get_argocd_password() {
  echo "--- 🔐 [6/6] Getting ArgoCD Admin Password ---"
  if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY-RUN: Skipping password retrieval."
      return 0
  fi

  local password
  if [[ -n "${ARGOCD_ADMIN_PASSWORD}" ]]; then
    password="${ARGOCD_ADMIN_PASSWORD}"
    echo "Using provided admin password from configuration."
  else
    # Try to get the auto-generated password from initial secret first
    password=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
    
    # If initial secret doesn't exist, check if there's a custom password in argocd-secret
    if [[ -z "$password" ]]; then
      echo "Initial admin secret not found, checking for custom password configuration..."
      # Check if argocd-secret exists and has admin.password field
      if kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-secret -o jsonpath="{.data.admin\.password}" >/dev/null 2>&1; then
        echo "⚠️  ArgoCD is configured with a custom password."
        echo "   The password is stored in bcrypt format in the argocd-secret."
        echo "   Use the password from your configuration (ARGOCD_ADMIN_PASSWORD in .env file)."
        return 0
      else
        echo "⚠️  Could not retrieve ArgoCD admin password. Check ArgoCD installation."
        return 1
      fi
    fi
  fi
  
  export RETRIEVED_ARGOCD_PASSWORD="$password"
  echo "✅ ArgoCD admin password retrieved."
}

# --- ORGANIZATIONAL SETUP FUNCTIONS ---

create_authelia_users_secret() {
  local users_file="${1:-authelia-users.yml}"
  local namespace="${2:-security}"
  
  if [[ ! -f "$users_file" ]]; then
    echo "⚠️  Authelia users file '$users_file' not found. Skipping secret creation."
    return 0
  fi
  
  echo "🔐 Creating Kubernetes secret 'authelia-users' in namespace '${namespace}'..."
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: Would create secret authelia-users from $users_file"
    return 0
  fi
  
  # Check if namespace exists
  if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
    echo "   Creating namespace: $namespace"
    kubectl create namespace "$namespace"
  fi
  
  # Delete existing secret if it exists
  if kubectl get secret authelia-users -n "$namespace" > /dev/null 2>&1; then
    echo "   Deleting existing secret authelia-users..."
    kubectl delete secret authelia-users -n "$namespace"
  fi
  
  # Create the secret
  echo "   Creating secret from file: $users_file"
  kubectl create secret generic authelia-users \
    --from-file=users.yml="$users_file" \
    -n "$namespace"
  
  if [[ $? -eq 0 ]]; then
    echo "✅ Kubernetes secret 'authelia-users' created successfully"
  else
    echo "❌ Failed to create Kubernetes secret 'authelia-users'"
    return 1
  fi
}

setup_organizational_structure() {
  echo "--- 🏢 [7/8] Setting up Organizational Structure ---"
  
  if [[ "${ORG_STRUCTURE_ENABLED}" != "true" ]]; then
    echo "Organizational structure setup is disabled. Skipping."
    return 0
  fi
  
  if [[ ! -f "${ORG_CONFIG_FILE}" ]]; then
    echo "⚠️  Organizational configuration file '${ORG_CONFIG_FILE}' not found."
    echo "   Creating example configuration file..."
    
    if [[ "${DRY_RUN}" != "true" ]]; then
      mkdir -p "$(dirname "${ORG_CONFIG_FILE}")"
      if [[ ! -f "config/organizations.yaml" ]]; then
        echo "   Example file already exists at config/organizations.yaml"
      fi
    fi
    
    echo "   Please customize ${ORG_CONFIG_FILE} and re-run the installer."
    echo "   The installer will continue without organizational setup."
    return 0
  fi
  
  echo "📋 Found organizational configuration: ${ORG_CONFIG_FILE}"
  
  # Generate Authelia users configuration
  if [[ "${AUTO_SETUP_AUTHELIA_USERS}" == "true" ]]; then
    echo "🔐 Generating Authelia users configuration..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY-RUN: Would generate Authelia users from ${ORG_CONFIG_FILE}"
    else
      if [[ -x "scripts/generate-authelia-users.sh" ]]; then
        echo "   Running: ./scripts/generate-authelia-users.sh ${ORG_CONFIG_FILE}"
        ./scripts/generate-authelia-users.sh "${ORG_CONFIG_FILE}"
        
        # Create Kubernetes secret with the generated users
        echo "   Creating Kubernetes secret for Authelia users..."
        if [[ -f "authelia-users.yml" ]]; then
          create_authelia_users_secret "authelia-users.yml" "security"
        else
          echo "   ⚠️  Generated users file 'authelia-users.yml' not found"
          echo "   Checking alternative location: k8s-manifests/authelia-users.yaml"
          if [[ -f "k8s-manifests/authelia-users.yaml" ]]; then
            # Extract users data from the yaml manifest if it exists
            echo "   ⚠️  Found old manifest format. Please run generate-authelia-users.sh to create new format."
          fi
        fi
      else
        echo "   ❌ Script scripts/generate-authelia-users.sh not found or not executable"
      fi
    fi
  fi
  
  # Wait for applications to be ready before setting up organizations
  echo "⏳ Waiting for Gitea to be ready..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    local max_wait=300  # 5 minutes
    local wait_time=0
    
    while ! curl -s -f "https://git.${PUBLIC_DOMAIN}" > /dev/null; do
      if [[ $wait_time -ge $max_wait ]]; then
        echo "   ⚠️  Timeout waiting for Gitea to be ready. Skipping organizational setup."
        echo "   You can run organizational setup manually later with:"
        echo "   ./scripts/setup-gitea-organizations.sh ${ORG_CONFIG_FILE}"
        return 0
      fi
      
      echo "   Waiting for Gitea... (${wait_time}s/${max_wait}s)"
      sleep 10
      ((wait_time += 10))
    done
  fi
  
  # Setup Gitea organizations
  if [[ "${AUTO_SETUP_ORGS}" == "true" ]]; then
    echo "🏢 Setting up Gitea organizations..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "DRY-RUN: Would setup Gitea organizations from ${ORG_CONFIG_FILE}"
    else
      if [[ -x "scripts/setup-gitea-organizations.sh" ]]; then
        echo "   Running: ./scripts/setup-gitea-organizations.sh ${ORG_CONFIG_FILE}"
        ./scripts/setup-gitea-organizations.sh "${ORG_CONFIG_FILE}" || {
          echo "   ⚠️  Organizational setup failed. You can run it manually later with:"
          echo "   ./scripts/setup-gitea-organizations.sh ${ORG_CONFIG_FILE}"
        }
      else
        echo "   ❌ Script scripts/setup-gitea-organizations.sh not found or not executable"
      fi
    fi
  fi
  
  echo "✅ Organizational structure setup completed!"
}

# --- AUTHELIA ADMIN SETUP ---

setup_authelia_admin() {
  echo "--- 🔐 [Optional] Setting up Authelia Admin User ---"
  
  if [[ "${AUTO_SETUP_AUTHELIA_USERS}" != "true" ]]; then
    echo "Authelia admin setup is disabled. Skipping."
    return 0
  fi
  
  echo "🔐 Setting up Authelia admin user for first-time login..."
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY-RUN: Would setup Authelia admin user"
    return 0
  fi
  
  # Wait for Authelia to be ready
  echo "⏳ Waiting for Authelia to be ready..."
  local max_wait=120
  local wait_time=0
  
  while ! kubectl get deployment authelia -n authelia &>/dev/null; do
    if [[ $wait_time -ge $max_wait ]]; then
      echo "   ⚠️  Timeout waiting for Authelia deployment. Skipping admin setup."
      echo "   You can run admin setup manually later with:"
      echo "   ./scripts/setup-authelia-admin.sh"
      return 0
    fi
    
    echo "   Waiting for Authelia deployment... (${wait_time}s/${max_wait}s)"
    sleep 10
    ((wait_time += 10))
  done
  
  # Run the admin setup script
  if [[ -x "scripts/setup-authelia-admin.sh" ]]; then
    echo "   Running: ./scripts/setup-authelia-admin.sh"
    
    # Export Authelia configuration for the script
    export AUTHELIA_NAMESPACE="authelia"
    export AUTHELIA_HOST="${AUTHELIA_HOST}"
    export AUTHELIA_ADMIN_USERNAME="${AUTHELIA_ADMIN_USERNAME}"
    export AUTHELIA_ADMIN_PASSWORD="${AUTHELIA_ADMIN_PASSWORD}"
    export AUTHELIA_ADMIN_EMAIL="${AUTHELIA_ADMIN_EMAIL}"
    
    ./scripts/setup-authelia-admin.sh || {
      echo "   ⚠️  Authelia admin setup failed. You can run it manually later with:"
      echo "   ./scripts/setup-authelia-admin.sh"
      return 0
    }
  else
    echo "   ⚠️  Script scripts/setup-authelia-admin.sh not found or not executable"
    echo "   Skipping automated admin setup"
  fi
  
  echo "✅ Authelia admin setup completed!"
}

post_installation_summary() {
  echo "--- 📋 [8/8] Post-Installation Summary ---"
  
  echo ""
  echo "🎉 K3s Homelab Installation Completed! 🎉"
  echo ""
  echo "🌐 Access Information:"
  echo "   ArgoCD: https://${ARGOCD_HOST}"
  echo "   Gitea: https://git.${PUBLIC_DOMAIN}"
  echo "   Grafana: https://observe.rtm.${PUBLIC_DOMAIN}"
  echo "   Authelia: https://authelia.rtm.${PUBLIC_DOMAIN}"
  echo ""
  echo "🔐 Default Credentials:"
  echo "   ArgoCD Admin: admin / ${RETRIEVED_ARGOCD_PASSWORD:-<see instructions below>}"
  echo "   Gitea Admin: smii / takeover"
  echo "   Authelia: smii / takeover"
  echo ""
  if [[ "${ORG_STRUCTURE_ENABLED}" == "true" ]]; then
    echo "🏢 Organizational Structure:"
    echo "   ✅ Authelia users configured from ${ORG_CONFIG_FILE}"
    echo "   ✅ Gitea organizations and teams created"
    echo "   ✅ Project-based access control implemented"
    echo ""
    echo "   Project Users Pattern:"
    echo "   - {project}-admin: Administrative rights"
    echo "   - {project}-developers: Push/write access"
    echo "   - {project}-viewers: Read-only access"
    echo ""
  fi
  echo "📋 Applications Deployed via ArgoCD:"
  echo "   ✓ Traefik (Ingress Controller)"
  echo "   ✓ Sealed Secrets (Secret Management)"
  echo "   ✓ Prometheus Stack (Monitoring)"
  echo "   ✓ Grafana Loki + Fluent Bit (Logging)"
  echo "   ✓ Authelia (Authentication & SSO)"
  echo "   ✓ Harbor (Container Registry)"
  echo "   ✓ Gitea (Git Repository with SSO)"
  echo "   ✓ CrowdSec (Security)"
  echo "   ✓ Jupyter Notebook (Data Science)"
  echo "   ✓ Uptime Kuma (Monitoring)"
  echo "   ✓ Hugo Blog (Static Site)"
  echo ""
}

main() {
  # Default to '.env' if no file path is provided as the first argument
  local ENV_FILE="${1:-.env}"
  
  echo "=========================================="
  echo "    🏠 K3s Homelab GitOps Installer"
  echo "=========================================="
  echo ""
  
  config_vars "$ENV_FILE"
  
  # --- GENERATE CONFIGS ---
  generate_configs "$ENV_FILE"
  
  # --- INSTALLATION STEPS ---
  install_k3s
  setup_kubeconfig
  wait_for_k3s
  install_helm
  install_argocd_cli
  install_argocd
  wait_for_argocd
  configure_argocd_repositories
  deploy_argocd_projects
  deploy_bootstrap_application
  get_argocd_password
  
  # --- ORGANIZATIONAL SETUP ---
  setup_organizational_structure
  
  # --- AUTHELIA ADMIN SETUP ---
  setup_authelia_admin
  
  # --- SUMMARY ---
  post_installation_summary
}

main "$@"