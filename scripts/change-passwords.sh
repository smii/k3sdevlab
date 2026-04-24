#!/usr/bin/env bash
# scripts/change-passwords.sh
# Change the password for one or all Authelia users.
#
# Usage:
#   ./scripts/change-passwords.sh                        # interactive — prompts for user + password
#   ./scripts/change-passwords.sh <username> <password>  # change a single user non-interactively
#   ./scripts/change-passwords.sh --all <password>       # change ALL 14 users to the same password
#
# After updating passwords the script re-applies the authelia-users secret and
# restarts the Authelia pod so the new credentials take effect immediately.
#
# Requirements: kubectl in PATH, access to the cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
USERS_FILE="${REPO_ROOT}/authelia-users.yml"
NAMESPACE="authelia"

ALL_USERS=(smii alice bob carol dave eve frank grace henry ivan judy karl linda viewer)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found in PATH." >&2
    exit 1
  fi
}

generate_hash() {
  local password="$1"
  local hash=""

  if command -v authelia &>/dev/null; then
    hash=$(authelia crypto hash generate argon2 --password "$password" 2>/dev/null \
      | grep 'Digest:' | awk '{print $2}' || true)
  fi

  if [[ -z "$hash" ]] && command -v docker &>/dev/null; then
    echo "  Generating hash via Docker..." >&2
    hash=$(docker run --rm authelia/authelia:latest \
      authelia crypto hash generate argon2 --password "$password" 2>/dev/null \
      | grep 'Digest:' | awk '{print $2}' || true)
  fi

  if [[ -z "$hash" ]]; then
    echo "ERROR: Neither 'authelia' binary nor Docker is available." >&2
    echo "       Install one and retry, or manually compute the hash with:" >&2
    echo "       docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password '<password>'" >&2
    exit 1
  fi

  echo "$hash"
}

update_user_hash() {
  local username="$1"
  local new_hash="$2"

  # Validate user exists in the file
  if ! grep -q "^  ${username}:" "$USERS_FILE"; then
    echo "ERROR: user '${username}' not found in ${USERS_FILE}" >&2
    exit 1
  fi

  # Replace the password line for this specific user block.
  # Uses awk to scope the replacement to the correct user stanza.
  awk -v user="${username}" -v hash="${new_hash}" '
    /^  [a-z]+:/ { in_user = ($0 ~ "^  " user ":") }
    in_user && /^    password:/ {
      print "    password: \"" hash "\""
      next
    }
    { print }
  ' "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

  echo "  [OK] ${username}: password hash updated"
}

apply_secret() {
  echo ""
  echo "=== Applying authelia-users secret ==="
  kubectl create secret generic authelia-users \
    --from-file=users.yml="${USERS_FILE}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret applied."
}

restart_authelia() {
  echo ""
  echo "=== Restarting Authelia ==="
  kubectl rollout restart daemonset/authelia -n "${NAMESPACE}"
  kubectl rollout status daemonset/authelia -n "${NAMESPACE}" --timeout=120s
  echo "Authelia restarted and ready."
}

regenerate_totp() {
  local username="$1"
  echo ""
  echo "=== Re-generating TOTP for ${username} ==="
  local pod
  pod=$(kubectl get pods -n "${NAMESPACE}" -o name | head -1 | cut -d/ -f2)
  kubectl exec -n "${NAMESPACE}" "${pod}" -- \
    authelia storage user totp generate "${username}" --config /configuration.yaml --force
  echo ""
  echo "Scan the otpauth:// URI above with your authenticator app."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

require_cmd kubectl

MODE=""
TARGET_USER=""
TARGET_PASS=""

# Parse arguments
if [[ $# -eq 0 ]]; then
  MODE="interactive"
elif [[ "$1" == "--all" ]]; then
  MODE="all"
  TARGET_PASS="${2:-}"
  if [[ -z "$TARGET_PASS" ]]; then
    read -rsp "New password for ALL users: " TARGET_PASS
    echo ""
    read -rsp "Confirm password: " CONFIRM_PASS
    echo ""
    if [[ "$TARGET_PASS" != "$CONFIRM_PASS" ]]; then
      echo "ERROR: passwords do not match." >&2
      exit 1
    fi
  fi
elif [[ $# -ge 2 ]]; then
  MODE="single"
  TARGET_USER="$1"
  TARGET_PASS="$2"
else
  echo "Usage:"
  echo "  $0                         # interactive"
  echo "  $0 <username> <password>   # single user"
  echo "  $0 --all <password>        # all users"
  exit 1
fi

# Interactive mode
if [[ "$MODE" == "interactive" ]]; then
  echo "Available users: ${ALL_USERS[*]}"
  echo ""
  read -rp "Username (or 'all'): " TARGET_USER
  if [[ "$TARGET_USER" == "all" ]]; then
    MODE="all"
    TARGET_USER=""
  else
    MODE="single"
  fi
  read -rsp "New password: " TARGET_PASS
  echo ""
  read -rsp "Confirm password: " CONFIRM_PASS
  echo ""
  if [[ "$TARGET_PASS" != "$CONFIRM_PASS" ]]; then
    echo "ERROR: passwords do not match." >&2
    exit 1
  fi
fi

echo ""
echo "=== Generating argon2id hash (this takes a few seconds) ==="
NEW_HASH=$(generate_hash "$TARGET_PASS")
echo "  Hash computed: ${NEW_HASH:0:40}..."

echo ""
echo "=== Updating ${USERS_FILE} ==="

if [[ "$MODE" == "all" ]]; then
  for u in "${ALL_USERS[@]}"; do
    update_user_hash "$u" "$NEW_HASH"
  done
else
  update_user_hash "$TARGET_USER" "$NEW_HASH"
fi

apply_secret
restart_authelia

echo ""
echo "=== Password change complete ==="
echo ""
echo "If the user has TOTP pre-registered and you also want to re-enroll their"
echo "authenticator app, run:"
if [[ "$MODE" == "all" ]]; then
  echo "  for u in ${ALL_USERS[*]}; do"
  echo "    $0 --regen-totp \$u"
  echo "  done"
  echo ""
  echo "Or run the TOTP loop directly:"
  cat <<'EOF'
  POD=$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)
  for user in smii alice bob carol dave eve frank grace henry ivan judy karl linda viewer; do
    kubectl exec -n authelia $POD -- \
      authelia storage user totp generate $user --config /configuration.yaml --force
  done
EOF
else
  echo "  POD=\$(kubectl get pods -n authelia -o name | head -1 | cut -d/ -f2)"
  echo "  kubectl exec -n authelia \$POD -- \\"
  echo "    authelia storage user totp generate ${TARGET_USER} --config /configuration.yaml --force"
fi
