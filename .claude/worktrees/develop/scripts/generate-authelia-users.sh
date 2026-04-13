#!/usr/bin/env bash
# scripts/generate-authelia-users.sh
# Regenerates authelia-users.yml from personas defined in this script,
# using group definitions from config/organizations.yaml.
#
# Usage: ./scripts/generate-authelia-users.sh [.env file path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${REPO_ROOT}/.env}"
OUTPUT="${REPO_ROOT}/authelia-users.yml"
NAMESPACE="authelia"

# Load env
source "$ENV_FILE" 2>/dev/null || { echo "Cannot load $ENV_FILE"; exit 1; }

echo "=== Generating authelia-users.yml ==="

# Try to generate a fresh hash for Homelab2024! if authelia binary available
HASH=""
if command -v authelia &>/dev/null; then
  HASH=$(authelia crypto hash generate argon2 --password 'Homelab2024!' 2>/dev/null | grep 'Digest:' | awk '{print $2}' || true)
fi

if [[ -z "$HASH" ]] && command -v docker &>/dev/null; then
  echo "Generating hash via Docker..."
  HASH=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 \
    --password 'Homelab2024!' 2>/dev/null | grep 'Digest:' | awk '{print $2}' || true)
fi

if [[ -z "$HASH" ]]; then
  echo "WARNING: Could not generate fresh hash. Using pre-computed placeholder hash."
  echo "         Run: docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'Homelab2024!'"
  echo "         and update authelia-users.yml with the output."
  HASH='$argon2id$v=19$m=65536,t=3,p=4$iNAxAzKLla3N4gUkjFWNHw$sXfdJEAbBL57ZoQc9PKyUA'
fi

echo "Using hash: ${HASH:0:30}..."

cat > "$OUTPUT" << USERSEOF
users:
  # All passwords are 'Homelab2024!' hashed with argon2id.
  # To regenerate: docker run authelia/authelia:latest authelia crypto hash generate argon2 --password 'Homelab2024!'
  smii:
    displayname: "System Administrator"
    password: "${HASH}"
    email: "mj.lopes@gmail.com"
    groups:
      - admins
      - homelab_prd
      - webapp_prd
      - devops_prd
      - platform_prd
  alice:
    displayname: "Alice Dev"
    password: "${HASH}"
    email: "alice@kubernative.io"
    groups:
      - homelab_dev
  bob:
    displayname: "Bob QA"
    password: "${HASH}"
    email: "bob@kubernative.io"
    groups:
      - homelab_test
  carol:
    displayname: "Carol Ops"
    password: "${HASH}"
    email: "carol@kubernative.io"
    groups:
      - homelab_prd
  dave:
    displayname: "Dave WebDev"
    password: "${HASH}"
    email: "dave@kubernative.io"
    groups:
      - webapp_dev
  eve:
    displayname: "Eve WebQA"
    password: "${HASH}"
    email: "eve@kubernative.io"
    groups:
      - webapp_test
  frank:
    displayname: "Frank WebOps"
    password: "${HASH}"
    email: "frank@kubernative.io"
    groups:
      - webapp_prd
  grace:
    displayname: "Grace DevopsEng"
    password: "${HASH}"
    email: "grace@kubernative.io"
    groups:
      - devops_dev
  henry:
    displayname: "Henry DevopsQA"
    password: "${HASH}"
    email: "henry@kubernative.io"
    groups:
      - devops_test
  ivan:
    displayname: "Ivan DevopsOps"
    password: "${HASH}"
    email: "ivan@kubernative.io"
    groups:
      - devops_prd
  judy:
    displayname: "Judy Platform"
    password: "${HASH}"
    email: "judy@kubernative.io"
    groups:
      - platform_dev
  karl:
    displayname: "Karl PlatformQA"
    password: "${HASH}"
    email: "karl@kubernative.io"
    groups:
      - platform_test
  linda:
    displayname: "Linda PlatformOps"
    password: "${HASH}"
    email: "linda@kubernative.io"
    groups:
      - platform_prd
  viewer:
    displayname: "Read Only User"
    password: "${HASH}"
    email: "viewer@kubernative.io"
    groups:
      - viewers
USERSEOF

echo "Written: $OUTPUT"

# Apply as Kubernetes secret
echo ""
echo "=== Applying authelia-users secret to Kubernetes ==="
if command -v kubectl &>/dev/null; then
  kubectl create secret generic authelia-users \
    --from-file=users.yml="${OUTPUT}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret applied to namespace: ${NAMESPACE}"
else
  echo "kubectl not found — skipping secret apply."
  echo "Run manually: kubectl create secret generic authelia-users --from-file=users.yml=${OUTPUT} -n ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -"
fi

echo ""
echo "Done."
