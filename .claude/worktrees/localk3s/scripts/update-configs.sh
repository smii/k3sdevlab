#!/usr/bin/env bash
set -euo pipefail

# Script to update configuration files based on environment variables
# Usage: ./scripts/update-configs.sh [env_file]

ENV_FILE="${1:-.env}"

if [[ -f "$ENV_FILE" ]]; then
    echo "Loading configuration from ${ENV_FILE}..."
    # Use set -a to automatically export variables
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Warning: ${ENV_FILE} not found. Using current environment variables."
fi

# Set defaults for variables if they are not set
: "${PUBLIC_DOMAIN:=containers.io}"
: "${LOCAL_DOMAIN:=localdomain.local}"
: "${TRAEFIK_DASHBOARD_HOST:=traefik.${LOCAL_DOMAIN}}"
: "${AUTHELIA_HOST:=authelia.rtm.${PUBLIC_DOMAIN}}"
: "${GRAFANA_ADMIN_PASSWORD:=takeover}"
: "${GITEA_HOST:=git.${PUBLIC_DOMAIN}}"
: "${GITEA_ADMIN_USERNAME:=smii}"
: "${GITEA_ADMIN_PASSWORD:=takeover}"
: "${GITEA_ADMIN_EMAIL:=admin@${LOCAL_DOMAIN}}"
: "${GITHUB_REPO:=https://github.com/smii/k3sdevlab}"
: "${CROWDSEC_ENABLED:=true}"

# Export variables explicitly to be sure
export PUBLIC_DOMAIN LOCAL_DOMAIN TRAEFIK_DASHBOARD_HOST AUTHELIA_HOST GRAFANA_ADMIN_PASSWORD GITEA_HOST GITEA_ADMIN_USERNAME GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL GITHUB_REPO CROWDSEC_ENABLED

echo "Generating configuration files from templates..."

# Function to process template
process_template() {
    local template="$1"
    local output="${template%.template}"
    
    if [[ -f "$template" ]]; then
        echo "Processing $template -> $output"
        # We use envsubst to replace variables. 
        # We specify exactly which variables to replace to avoid messing up Helm templates.
        envsubst '$PUBLIC_DOMAIN $LOCAL_DOMAIN $TRAEFIK_DASHBOARD_HOST $AUTHELIA_HOST $GRAFANA_ADMIN_PASSWORD $GITEA_HOST $GITEA_ADMIN_USERNAME $GITEA_ADMIN_PASSWORD $GITEA_ADMIN_EMAIL' < "$template" > "$output"
    else
        echo "Warning: Template $template not found."
    fi
}

# Process the templates
process_template "charts/traefik/traefik-values.yaml.template"
process_template "charts/prometheus-stack/prometheus-values.yaml.template"
process_template "charts/authelia/authelia-fixed.yaml.template"
process_template "charts/gitea/gitea-values.yaml.template"

echo "Configuration files generated."

# Handle CrowdSec enablement
if [[ "${CROWDSEC_ENABLED}" == "false" ]]; then
    if [[ -f "argocd/applications/security/crowdsec.yaml" ]]; then
        echo "Disabling CrowdSec (renaming to .disabled)..."
        mv "argocd/applications/security/crowdsec.yaml" "argocd/applications/security/crowdsec.yaml.disabled"
    fi
else
    if [[ -f "argocd/applications/security/crowdsec.yaml.disabled" ]]; then
        echo "Enabling CrowdSec..."
        mv "argocd/applications/security/crowdsec.yaml.disabled" "argocd/applications/security/crowdsec.yaml"
    fi
fi

# Update ArgoCD Application repoURLs
echo "Updating ArgoCD Application repoURLs..."

# Define the old repo URLs to look for
OLD_REPO_HTTPS="https://github.com/smii/k3sdevlab"
OLD_REPO_GIT="git@github.com:smii/k3sdevlab.git"

# Find all yaml files in argocd/applications
find argocd/applications -name "*.yaml" -type f | while read -r file; do
    # Check if the file contains the old repo URL
    if grep -q "$OLD_REPO_HTTPS" "$file" || grep -q "$OLD_REPO_GIT" "$file"; then
        echo "Updating repoURL in $file"
        # Replace https URL
        sed -i "s|repoURL: $OLD_REPO_HTTPS|repoURL: ${GITHUB_REPO}|g" "$file"
        # Replace git URL
        sed -i "s|repoURL: $OLD_REPO_GIT|repoURL: ${GITHUB_REPO}|g" "$file"
    fi
done

echo "ArgoCD Applications updated."
echo ""
echo "⚠️  IMPORTANT: You must commit and push these changes to your Git repository"
echo "   before ArgoCD can sync the applications correctly."
echo ""
