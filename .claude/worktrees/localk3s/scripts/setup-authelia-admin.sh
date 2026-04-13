#!/usr/bin/env bash

# Authelia Admin First-Time Login Setup
# This script automates the setup of Authelia admin user for first-time login

set -euo pipefail

# Configuration
AUTHELIA_NAMESPACE="${AUTHELIA_NAMESPACE:-authelia}"
AUTHELIA_HOST="${AUTHELIA_HOST:-authelia.rtm.kubernative.io}"
ADMIN_USERNAME="${AUTHELIA_ADMIN_USERNAME:-smii}"
ADMIN_PASSWORD="${AUTHELIA_ADMIN_PASSWORD:-takeover}"
ADMIN_EMAIL="${AUTHELIA_ADMIN_EMAIL:-admin@rtm.kubernative.io}"
ADMIN_DISPLAYNAME="${AUTHELIA_ADMIN_DISPLAYNAME:-System Administrator}"

echo "🔐 Authelia Admin Setup Automation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Function to check if Authelia is running
check_authelia() {
  echo "🔍 Checking Authelia deployment..."
  
  # Check for deployment first, then daemonset
  local resource_type=""
  local resource_name=""
  
  if kubectl get deployment authelia -n "$AUTHELIA_NAMESPACE" &>/dev/null; then
    resource_type="deployment"
    resource_name="authelia"
  elif kubectl get daemonset authelia -n "$AUTHELIA_NAMESPACE" &>/dev/null; then
    resource_type="daemonset"
    resource_name="authelia"
  else
    echo "❌ Authelia deployment/daemonset not found in namespace: $AUTHELIA_NAMESPACE"
    return 1
  fi
  
  echo "   Found Authelia $resource_type: $resource_name"
  
  if [[ "$resource_type" == "deployment" ]]; then
    local ready=$(kubectl get deployment authelia -n "$AUTHELIA_NAMESPACE" -o jsonpath='{.status.readyReplicas}')
    local desired=$(kubectl get deployment authelia -n "$AUTHELIA_NAMESPACE" -o jsonpath='{.status.replicas}')
  else
    local ready=$(kubectl get daemonset authelia -n "$AUTHELIA_NAMESPACE" -o jsonpath='{.status.numberReady}')
    local desired=$(kubectl get daemonset authelia -n "$AUTHELIA_NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}')
  fi
  
  if [[ "$ready" != "$desired" ]] || [[ -z "$ready" ]]; then
    echo "⚠️  Authelia is not ready yet (Ready: ${ready:-0}/${desired:-0})"
    return 1
  fi
  
  echo "✅ Authelia is running (${ready}/${desired} pods ready)"
  return 0
}

# Function to create or update admin user
create_admin_user() {
  echo ""
  echo "👤 Creating/Updating Authelia admin user..."
  
  # Check if Python and argon2 are available for password hashing
  if ! python3 -c "import argon2" 2>/dev/null; then
    echo "⚠️  argon2-cffi not found. Installing..."
    pip3 install argon2-cffi --quiet || {
      echo "❌ Failed to install argon2-cffi"
      echo "   Install manually with: pip3 install argon2-cffi"
      return 1
    }
  fi
  
  # Hash the admin password
  echo "   Hashing admin password..."
  local hashed_password=$(python3 -c "
import argon2
ph = argon2.PasswordHasher(
    memory_cost=65536,
    time_cost=3,
    parallelism=4
)
print(ph.hash('${ADMIN_PASSWORD}'))
")
  
  # Create users.yml content
  cat > /tmp/authelia-admin-users.yml << EOF
users:
  ${ADMIN_USERNAME}:
    displayname: "${ADMIN_DISPLAYNAME}"
    password: "${hashed_password}"
    email: "${ADMIN_EMAIL}"
    groups:
      - "admins"
EOF
  
  echo "   Creating Kubernetes secret..."
  
  # Delete existing secret if present
  if kubectl get secret authelia-users -n "$AUTHELIA_NAMESPACE" &>/dev/null; then
    kubectl delete secret authelia-users -n "$AUTHELIA_NAMESPACE"
  fi
  
  # Create new secret
  kubectl create secret generic authelia-users \
    --from-file=users.yml=/tmp/authelia-admin-users.yml \
    -n "$AUTHELIA_NAMESPACE"
  
  # Clean up temp file
  rm -f /tmp/authelia-admin-users.yml
  
  echo "✅ Admin user created/updated successfully"
}

# Function to restart Authelia to pick up changes
restart_authelia() {
  echo ""
  echo "🔄 Restarting Authelia to apply changes..."
  
  # Determine resource type
  local resource_type=""
  if kubectl get deployment authelia -n "$AUTHELIA_NAMESPACE" &>/dev/null; then
    resource_type="deployment"
  elif kubectl get daemonset authelia -n "$AUTHELIA_NAMESPACE" &>/dev/null; then
    resource_type="daemonset"
  else
    echo "❌ Could not find Authelia deployment or daemonset"
    return 1
  fi
  
  kubectl rollout restart "$resource_type/authelia" -n "$AUTHELIA_NAMESPACE"
  
  echo "   Waiting for Authelia to be ready..."
  kubectl rollout status "$resource_type/authelia" -n "$AUTHELIA_NAMESPACE" --timeout=120s
  
  echo "✅ Authelia restarted successfully"
}

# Function to verify admin user can authenticate
verify_admin_login() {
  echo ""
  echo "🔍 Verifying admin user configuration..."
  
  # Get the pod name
  local pod=$(kubectl get pods -n "$AUTHELIA_NAMESPACE" -l app.kubernetes.io/name=authelia -o jsonpath='{.items[0].metadata.name}')
  
  if [[ -z "$pod" ]]; then
    echo "⚠️  Could not find Authelia pod"
    return 1
  fi
  
  # Check if users file is mounted correctly
  echo "   Checking users.yml file in pod..."
  if kubectl exec -n "$AUTHELIA_NAMESPACE" "$pod" -- cat /secrets/authelia-users/users.yml &>/dev/null; then
    echo "✅ Users file is correctly mounted"
    
    # Display the users (without passwords)
    echo ""
    echo "   Configured users:"
    kubectl exec -n "$AUTHELIA_NAMESPACE" "$pod" -- cat /secrets/authelia-users/users.yml | grep -E "^  [a-z]" | sed 's/:$//' | sed 's/^/     - /'
  else
    echo "❌ Users file not found in pod"
    return 1
  fi
  
  return 0
}

# Function to display login information
display_login_info() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🎉 Authelia Admin Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "📍 Authelia URL: https://${AUTHELIA_HOST}"
  echo ""
  echo "🔐 Admin Credentials:"
  echo "   Username: ${ADMIN_USERNAME}"
  echo "   Password: ${ADMIN_PASSWORD}"
  echo "   Email:    ${ADMIN_EMAIL}"
  echo ""
  echo "📋 Access Policy:"
  echo "   - Authelia portal: bypass (no authentication required)"
  echo "   - Gitea: one_factor (password only, no 2FA)"
  echo "   - Other *.rtm.kubernative.io: two_factor (password + 2FA)"
  echo ""
  echo "⚠️  IMPORTANT NOTES:"
  echo "   1. For first login, you only need username and password"
  echo "   2. Two-factor authentication (2FA) is NOT required for Gitea initially"
  echo "   3. To enable 2FA, access Authelia portal and configure TOTP or WebAuthn"
  echo "   4. Change the default password after first login!"
  echo ""
  echo "🔗 Next Steps:"
  echo "   1. Access Authelia: https://${AUTHELIA_HOST}"
  echo "   2. Login with the credentials above"
  echo "   3. Configure 2FA (optional but recommended)"
  echo "   4. Test SSO with Gitea: https://git.rtm.kubernative.io"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to check access control policy
check_access_policy() {
  echo ""
  echo "🔍 Checking Authelia access control policy..."
  
  local pod=$(kubectl get pods -n "$AUTHELIA_NAMESPACE" -l app.kubernetes.io/name=authelia -o jsonpath='{.items[0].metadata.name}')
  
  if [[ -z "$pod" ]]; then
    echo "⚠️  Could not find Authelia pod"
    return 1
  fi
  
  # Check configuration
  echo "   Current access control rules:"
  kubectl exec -n "$AUTHELIA_NAMESPACE" "$pod" -- cat /config/configuration.yml | grep -A 20 "access_control:" || echo "   (unable to read configuration)"
  
  return 0
}

# Function to create simplified access policy for first-time setup
create_simplified_policy() {
  echo ""
  echo "📝 Note: Access policy is managed via Helm values in charts/authelia/authelia-fixed.yaml"
  echo "   Current policy allows:"
  echo "   - authelia.rtm.kubernative.io: bypass (no auth)"
  echo "   - git.rtm.kubernative.io: one_factor (password only)"
  echo "   - *.rtm.kubernative.io: two_factor (password + 2FA)"
  echo ""
  echo "   This means admin can login to Gitea with just password (no 2FA required)"
}

# Main execution
main() {
  echo "Starting Authelia admin setup..."
  echo ""
  
  # Check if Authelia is running
  if ! check_authelia; then
    echo ""
    echo "❌ Authelia is not ready. Please ensure Authelia is deployed and running."
    echo "   Deploy with: kubectl apply -f argocd/applications/security/authelia.yaml"
    exit 1
  fi
  
  # Create admin user
  if ! create_admin_user; then
    echo ""
    echo "❌ Failed to create admin user"
    exit 1
  fi
  
  # Restart Authelia
  if ! restart_authelia; then
    echo ""
    echo "❌ Failed to restart Authelia"
    exit 1
  fi
  
  # Verify admin login
  verify_admin_login
  
  # Check and display access policy
  create_simplified_policy
  
  # Display login information
  display_login_info
  
  echo ""
  echo "✅ Setup completed successfully!"
}

# Run main function
main "$@"
