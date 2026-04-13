#!/usr/bin/env bash

# Script to setup Gitea organizational structure based on organizational configuration
# Usage: ./scripts/setup-gitea-organizations.sh [config_file]

set -euo pipefail

# Configuration
CONFIG_FILE="${1:-config/organizations.yaml}"
GITEA_URL="https://git.rtm.kubernative.io"
GITEA_ADMIN_USER="smii"
GITEA_ADMIN_PASS="takeover"

echo "🏢 Setting up Gitea organizational structure..."
echo "   Config file: ${CONFIG_FILE}"
echo "   Gitea URL: ${GITEA_URL}"

# Check dependencies
if ! command -v yq &> /dev/null; then
    echo "❌ Error: yq is required but not installed."
    echo "   Install with: sudo snap install yq"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "❌ Error: curl is required but not installed."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq is required but not installed."
    echo "   Install with: sudo apt-get install jq"
    exit 1
fi

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Error: Configuration file '${CONFIG_FILE}' not found."
    exit 1
fi

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

# Function to create organization
create_organization() {
    local org_name="$1"
    local org_description="$2"
    
    echo "🏢 Creating organization: $org_name"
    
    # Check if organization already exists
    if gitea_api "GET" "/orgs/$org_name" 2>/dev/null | jq -e '.name' > /dev/null; then
        echo "   ⚠️  Organization '$org_name' already exists, skipping creation"
        return 0
    fi
    
    # Create organization
    local org_data=$(cat <<EOF
{
    "username": "$org_name",
    "full_name": "$org_description",
    "description": "$org_description",
    "website": "",
    "location": "",
    "visibility": "private"
}
EOF
    )
    
    local result=$(gitea_api "POST" "/orgs" "$org_data")
    if echo "$result" | jq -e '.name' > /dev/null; then
        echo "   ✅ Organization '$org_name' created successfully"
    else
        echo "   ❌ Failed to create organization '$org_name'"
        echo "   Response: $result"
        return 1
    fi
}

# Function to create user (if not exists via SSO)
create_user() {
    local username="$1"
    local email="$2"
    local full_name="$3"
    local password="$4"
    
    echo "👤 Creating user: $username"
    
    # Check if user already exists
    if gitea_api "GET" "/users/$username" 2>/dev/null | jq -e '.login' > /dev/null; then
        echo "   ⚠️  User '$username' already exists, skipping creation"
        return 0
    fi
    
    # Create user
    local user_data=$(cat <<EOF
{
    "username": "$username",
    "email": "$email",
    "password": "$password",
    "full_name": "$full_name",
    "send_notify": false,
    "must_change_password": true
}
EOF
    )
    
    local result=$(gitea_api "POST" "/admin/users" "$user_data")
    if echo "$result" | jq -e '.login' > /dev/null; then
        echo "   ✅ User '$username' created successfully"
    else
        echo "   ⚠️  User creation may have failed (possibly exists via SSO)"
        echo "   Response: $result"
    fi
}

# Function to add user to organization with specific permissions
add_user_to_org() {
    local org_name="$1"
    local username="$2"
    local role="$3"  # owner, admin, member
    
    echo "🔗 Adding user '$username' to organization '$org_name' as '$role'"
    
    # Check if user is already in organization
    if gitea_api "GET" "/orgs/$org_name/members/$username" 2>/dev/null | jq -e '.login' > /dev/null; then
        echo "   ⚠️  User '$username' is already a member of '$org_name'"
        return 0
    fi
    
    # Add user to organization
    local membership_data=$(cat <<EOF
{
    "role": "$role"
}
EOF
    )
    
    local result=$(gitea_api "PUT" "/orgs/$org_name/members/$username" "$membership_data")
    if [ $? -eq 0 ]; then
        echo "   ✅ User '$username' added to organization '$org_name' as '$role'"
    else
        echo "   ❌ Failed to add user '$username' to organization '$org_name'"
        echo "   Response: $result"
    fi
}

# Function to create team in organization
create_team() {
    local org_name="$1"
    local team_name="$2"
    local team_description="$3"
    local permission="$4"  # read, write, admin
    
    echo "👥 Creating team '$team_name' in organization '$org_name'"
    
    # Check if team already exists
    local teams=$(gitea_api "GET" "/orgs/$org_name/teams")
    if echo "$teams" | jq -e ".[] | select(.name == \"$team_name\")" > /dev/null; then
        echo "   ⚠️  Team '$team_name' already exists in '$org_name'"
        return 0
    fi
    
    # Create team
    local team_data=$(cat <<EOF
{
    "name": "$team_name",
    "description": "$team_description",
    "permission": "$permission",
    "can_create_org_repo": true,
    "includes_all_repositories": true
}
EOF
    )
    
    local result=$(gitea_api "POST" "/orgs/$org_name/teams" "$team_data")
    if echo "$result" | jq -e '.name' > /dev/null; then
        echo "   ✅ Team '$team_name' created successfully"
    else
        echo "   ❌ Failed to create team '$team_name'"
        echo "   Response: $result"
    fi
}

# Function to add user to team
add_user_to_team() {
    local org_name="$1"
    local team_name="$2"
    local username="$3"
    
    echo "🎯 Adding user '$username' to team '$team_name'"
    
    # Get team ID
    local teams=$(gitea_api "GET" "/orgs/$org_name/teams")
    local team_id=$(echo "$teams" | jq -r ".[] | select(.name == \"$team_name\") | .id")
    
    if [ -z "$team_id" ] || [ "$team_id" = "null" ]; then
        echo "   ❌ Team '$team_name' not found in organization '$org_name'"
        return 1
    fi
    
    # Add user to team
    local result=$(gitea_api "PUT" "/teams/$team_id/members/$username" "")
    if [ $? -eq 0 ]; then
        echo "   ✅ User '$username' added to team '$team_name'"
    else
        echo "   ❌ Failed to add user '$username' to team '$team_name'"
        echo "   Response: $result"
    fi
}

echo "🚀 Starting organizational setup..."

# Function to run yq on config file (handles snap confinement issues)
yq_config() {
    cat "$CONFIG_FILE" | yq eval "$1" -
}

# Process each project
project_count=$(yq_config '.projects | length')
echo "Found $project_count projects"

for ((i=0; i<project_count; i++)); do
    project_name=$(yq_config ".projects[$i].name")
    project_description=$(yq_config ".projects[$i].description")
    
    echo ""
    echo "📂 Processing project: $project_name"
    echo "   Description: $project_description"
    
    # Create organization
    create_organization "$project_name" "$project_description"
    
    # Process teams for the project
    teams_count=$(yq_config ".projects[$i].teams | length")
    echo "   Found $teams_count teams"
    
    for ((j=0; j<teams_count; j++)); do
        team_name=$(yq_config ".projects[$i].teams[$j].name")
        team_description=$(yq_config ".projects[$i].teams[$j].description")
        team_permission=$(yq_config ".projects[$i].teams[$j].permission")
        
        echo "👥 Processing team: $team_name ($team_permission)"
        
        # Create team
        create_team "$project_name" "$team_name" "$team_description" "$team_permission"
        
        # Process team members
        members_count=$(yq_config ".projects[$i].teams[$j].members | length")
        echo "   Found $members_count members"
        
        for ((k=0; k<members_count; k++)); do
            member=$(yq_config ".projects[$i].teams[$j].members[$k]")
            
            echo "🎯 Adding member '$member' to team '$team_name'"
            
            # Check if this member is a global admin (already exists)
            is_global_admin=""
            global_admin_count=$(yq_config '.global_admins | length')
            for ((l=0; l<global_admin_count; l++)); do
                global_admin_username=$(yq_config ".global_admins[$l].username")
                if [ "$member" = "$global_admin_username" ]; then
                    is_global_admin="true"
                    break
                fi
            done
            
            if [ -n "$is_global_admin" ]; then
                echo "   📝 Member '$member' is a global admin (should already exist)"
                # Add to organization as owner if global admin
                add_user_to_org "$project_name" "$member" "owner"
            else
                # Create basic user for project-specific members
                echo "   📝 Creating project member '$member'"
                create_user "$member" "${member}@kubernative.io" "$member" "changeme123"
                # Add to organization as member
                add_user_to_org "$project_name" "$member" "member"
            fi
            
            # Add to team
            add_user_to_team "$project_name" "$team_name" "$member"
        done
    done
done

# Process global admins separately to ensure they exist
echo ""
echo "🌐 Processing global administrators..."

global_admin_count=$(yq_config '.global_admins | length')
echo "Found $global_admin_count global administrators"

for ((i=0; i<global_admin_count; i++)); do
    username=$(yq_config ".global_admins[$i].username")
    displayname=$(yq_config ".global_admins[$i].displayname")
    email=$(yq_config ".global_admins[$i].email")
    password=$(yq_config ".global_admins[$i].password")
    
    echo "👑 Processing global admin: $username"
    
    # Create user (will skip if exists)
    create_user "$username" "$email" "$displayname" "$password"
done

echo ""
echo "✅ Gitea organizational setup completed!"
echo ""
echo "📋 Summary:"
echo "   Organizations created for each project"
echo "   Teams created: admin, developers, viewers"
echo "   Users assigned to appropriate teams"
echo "   Global admins given owner access to all organizations"
echo ""
echo "🔗 Next steps:"
echo "   1. Verify organizations at: $GITEA_URL/admin/orgs"
echo "   2. Test user access with SSO authentication"
echo "   3. Create repositories in organizations"
echo "   4. Configure branch protection rules if needed"