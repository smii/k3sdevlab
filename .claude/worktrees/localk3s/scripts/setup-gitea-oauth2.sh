#!/bin/bash
# Gitea OAuth2 Setup Script for Authelia Integration
# This script configures Gitea to use Authelia for authentication

set -euo pipefail

# Configuration
GITEA_URL="https://git.rtm.kubernative.io"
GITEA_ADMIN_USER="smii"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASSWORD:-CUBhMvnh63bfrlnP7Nci}"
AUTHELIA_URL="https://authelia.rtm.kubernative.io"

# OAuth2 Application Details
OAUTH_NAME="authelia"
OAUTH_REDIRECT_URI="${GITEA_URL}/user/oauth2/authelia/callback"
OAUTH_CLIENT_ID="gitea"
OAUTH_CLIENT_SECRET="${AUTHELIA_OIDC_GITEA_SECRET:-2c770e9c43fcf6f4270dd56505d276e79aaf9f6758d7a9f62ef8d286438c5e7f}"

# Authelia OIDC Endpoints
AUTHORIZATION_URL="${AUTHELIA_URL}/api/oidc/authorization"
TOKEN_URL="${AUTHELIA_URL}/api/oidc/token"
PROFILE_URL="${AUTHELIA_URL}/api/oidc/userinfo"

echo "🔧 Configuring Gitea OAuth2 for Authelia..."

# Function to make API calls to Gitea
gitea_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    if [ -n "$data" ]; then
        curl -s -X "$method" \
             -H "Content-Type: application/json" \
             -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASS" \
             -d "$data" \
             "$GITEA_URL/api/v1$endpoint"
    else
        curl -s -X "$method" \
             -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASS" \
             "$GITEA_URL/api/v1$endpoint"
    fi
}

# Check if Gitea is accessible
echo "📡 Checking Gitea accessibility..."
if ! curl -s -f "$GITEA_URL" > /dev/null; then
    echo "❌ Error: Gitea is not accessible at $GITEA_URL"
    echo "   Make sure Gitea is running and accessible"
    exit 1
fi

# Check if admin user exists and credentials work
echo "🔐 Verifying admin credentials..."
if ! gitea_api "GET" "/user" > /dev/null; then
    echo "❌ Error: Cannot authenticate with Gitea admin user"
    echo "   Please check GITEA_ADMIN_USER and GITEA_ADMIN_PASS"
    exit 1
fi

echo "✅ Admin credentials verified"

# Check if OAuth2 application already exists
echo "🔍 Checking for existing OAuth2 applications..."
existing_oauth=$(gitea_api "GET" "/admin/oauth2" || echo "[]")

if echo "$existing_oauth" | grep -q "\"name\":\"$OAUTH_NAME\""; then
    echo "⚠️  OAuth2 application '$OAUTH_NAME' already exists"
    echo "   Delete it manually from Gitea admin panel if you want to recreate"
    exit 0
fi

# Create OAuth2 application
echo "🔧 Creating OAuth2 application..."
oauth_data=$(cat <<EOF
{
    "name": "$OAUTH_NAME",
    "confidential_client": true,
    "redirect_uris": ["$OAUTH_REDIRECT_URI"]
}
EOF
)

oauth_result=$(gitea_api "POST" "/admin/oauth2" "$oauth_data")

if [ $? -eq 0 ]; then
    echo "✅ OAuth2 application created successfully"
    echo "📋 Application Details:"
    echo "   Name: $OAUTH_NAME"
    echo "   Client ID: $(echo "$oauth_result" | jq -r '.client_id // "Not available"')"
    echo "   Client Secret: $(echo "$oauth_result" | jq -r '.client_secret // "Not available"')"
    echo "   Redirect URI: $OAUTH_REDIRECT_URI"
else
    echo "❌ Failed to create OAuth2 application"
    exit 1
fi

# Manual configuration instructions
echo ""
echo "🔧 Manual Configuration Required:"
echo ""
echo "1. 📱 In Gitea Admin Panel (Site Administration > Authentication Sources):"
echo "   - Type: OAuth2"
echo "   - Authentication Name: authelia"
echo "   - OAuth2 Provider: OpenID Connect"
echo "   - Client ID: $OAUTH_CLIENT_ID"
echo "   - Client Secret: $OAUTH_CLIENT_SECRET"
echo "   - OpenID Connect Auto Discovery URL: ${AUTHELIA_URL}/.well-known/openid_configuration"
echo "   - OR manually set:"
echo "     * Authorization URL: $AUTHORIZATION_URL"
echo "     * Token URL: $TOKEN_URL"
echo "     * Profile URL: $PROFILE_URL"
echo "   - Additional Scopes: email profile groups"
echo "   - Claim name for username: preferred_username"
echo "   - Claim name for email: email"
echo "   - Claim name for full name: name"
echo ""
echo "2. 🔐 In Authelia (when working):"
echo "   - Ensure OIDC client 'gitea' is configured"
echo "   - Client Secret matches: $OAUTH_CLIENT_SECRET"
echo "   - Redirect URI matches: $OAUTH_REDIRECT_URI"
echo ""
echo "3. 🧪 Test the integration:"
echo "   - Logout from Gitea"
echo "   - Try login with 'Sign in with authelia' button"
echo "   - Should redirect to Authelia for authentication"
echo ""
echo "✅ OAuth2 setup completed!"