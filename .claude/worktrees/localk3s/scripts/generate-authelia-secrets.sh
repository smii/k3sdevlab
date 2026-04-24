#!/usr/bin/env bash

# Generate Authelia Secrets
# This script generates random secure values for Authelia configuration if not provided

set -euo pipefail

# Function to generate a random hex string of specified length
generate_random_hex() {
  local length="${1:-64}"
  openssl rand -hex $((length / 2))
}

# Function to generate a random base64 string of specified length
generate_random_base64() {
  local length="${1:-64}"
  openssl rand -base64 $((length * 3 / 4)) | tr -d '\n' | head -c "$length"
}

# Main function to generate Authelia secrets
generate_authelia_secrets() {
  echo "🔐 Generating Authelia secrets..."
  
  # JWT Secret (minimum 32 characters)
  if [[ -z "${AUTHELIA_JWT_SECRET:-}" ]]; then
    AUTHELIA_JWT_SECRET=$(generate_random_hex 64)
    echo "   Generated AUTHELIA_JWT_SECRET"
  else
    echo "   Using existing AUTHELIA_JWT_SECRET"
  fi
  
  # Session Secret (minimum 32 characters)
  if [[ -z "${AUTHELIA_SESSION_SECRET:-}" ]]; then
    AUTHELIA_SESSION_SECRET=$(generate_random_hex 64)
    echo "   Generated AUTHELIA_SESSION_SECRET"
  else
    echo "   Using existing AUTHELIA_SESSION_SECRET"
  fi
  
  # Storage Encryption Key (must be 32 characters for AES-256)
  if [[ -z "${AUTHELIA_STORAGE_ENCRYPTION_KEY:-}" ]]; then
    AUTHELIA_STORAGE_ENCRYPTION_KEY=$(generate_random_base64 64)
    echo "   Generated AUTHELIA_STORAGE_ENCRYPTION_KEY"
  else
    echo "   Using existing AUTHELIA_STORAGE_ENCRYPTION_KEY"
  fi
  
  # OIDC HMAC Secret (minimum 32 characters)
  if [[ -z "${AUTHELIA_OIDC_HMAC_SECRET:-}" ]]; then
    AUTHELIA_OIDC_HMAC_SECRET=$(generate_random_hex 64)
    echo "   Generated AUTHELIA_OIDC_HMAC_SECRET"
  else
    echo "   Using existing AUTHELIA_OIDC_HMAC_SECRET"
  fi
  
  # OIDC Gitea Client Secret
  if [[ -z "${AUTHELIA_OIDC_GITEA_CLIENT_SECRET:-}" ]]; then
    AUTHELIA_OIDC_GITEA_CLIENT_SECRET=$(generate_random_hex 48)
    echo "   Generated AUTHELIA_OIDC_GITEA_CLIENT_SECRET"
  else
    echo "   Using existing AUTHELIA_OIDC_GITEA_CLIENT_SECRET"
  fi
  
  # Export the generated secrets
  export AUTHELIA_JWT_SECRET
  export AUTHELIA_SESSION_SECRET
  export AUTHELIA_STORAGE_ENCRYPTION_KEY
  export AUTHELIA_OIDC_HMAC_SECRET
  export AUTHELIA_OIDC_GITEA_CLIENT_SECRET
  
  echo "✅ Authelia secrets ready"
}

# Function to update .env file with generated secrets
update_env_file() {
  local env_file="${1:-.env}"
  
  if [[ ! -f "$env_file" ]]; then
    echo "⚠️  Warning: $env_file not found, skipping .env update"
    return 0
  fi
  
  echo "📝 Updating $env_file with generated secrets..."
  
  # Create a temporary file
  local temp_file="${env_file}.tmp"
  cp "$env_file" "$temp_file"
  
  # Update secrets in the file
  sed -i "s|^AUTHELIA_JWT_SECRET=.*|AUTHELIA_JWT_SECRET=\"${AUTHELIA_JWT_SECRET}\"|g" "$temp_file"
  sed -i "s|^AUTHELIA_SESSION_SECRET=.*|AUTHELIA_SESSION_SECRET=\"${AUTHELIA_SESSION_SECRET}\"|g" "$temp_file"
  sed -i "s|^AUTHELIA_STORAGE_ENCRYPTION_KEY=.*|AUTHELIA_STORAGE_ENCRYPTION_KEY=\"${AUTHELIA_STORAGE_ENCRYPTION_KEY}\"|g" "$temp_file"
  sed -i "s|^AUTHELIA_OIDC_HMAC_SECRET=.*|AUTHELIA_OIDC_HMAC_SECRET=\"${AUTHELIA_OIDC_HMAC_SECRET}\"|g" "$temp_file"
  sed -i "s|^AUTHELIA_OIDC_GITEA_CLIENT_SECRET=.*|AUTHELIA_OIDC_GITEA_CLIENT_SECRET=\"${AUTHELIA_OIDC_GITEA_CLIENT_SECRET}\"|g" "$temp_file"
  
  # Replace original file
  mv "$temp_file" "$env_file"
  
  echo "✅ $env_file updated with secrets"
}

# Function to display the secrets
display_secrets() {
  cat <<EOF

🔐 Generated Authelia Secrets:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

AUTHELIA_JWT_SECRET="${AUTHELIA_JWT_SECRET}"
AUTHELIA_SESSION_SECRET="${AUTHELIA_SESSION_SECRET}"
AUTHELIA_STORAGE_ENCRYPTION_KEY="${AUTHELIA_STORAGE_ENCRYPTION_KEY}"
AUTHELIA_OIDC_HMAC_SECRET="${AUTHELIA_OIDC_HMAC_SECRET}"
AUTHELIA_OIDC_GITEA_CLIENT_SECRET="${AUTHELIA_OIDC_GITEA_CLIENT_SECRET}"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚠️  IMPORTANT: Store these secrets securely!
   These secrets have been exported to your environment.
   
EOF
}

# Main execution
main() {
  local env_file="${1:-.env}"
  local display_only="${2:-false}"
  
  # Generate the secrets
  generate_authelia_secrets
  
  # Update .env file if requested
  if [[ "$display_only" != "display-only" ]]; then
    if [[ -f "$env_file" ]]; then
      read -p "Update $env_file with generated secrets? [y/N] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        update_env_file "$env_file"
      fi
    fi
  fi
  
  # Display the secrets
  display_secrets
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
