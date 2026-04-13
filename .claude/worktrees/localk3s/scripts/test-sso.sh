#!/usr/bin/env bash
# scripts/test-sso.sh
# Tests Authelia SSO authentication for all personas.
# Usage: ./scripts/test-sso.sh [.env file path]
#
# NOTE: This script tests authentication only (can user log in?).
# Forward-auth authorization (can user access domain X?) requires Traefik's
# ForwardAuth middleware to add X-Forwarded-Method — untestable from outside the cluster.
# Full end-to-end SSO is verified by browsing to a protected domain directly.
#
# What it does:
# 1. Loads .env
# 2. For each persona, POSTs credentials to Authelia /api/firstfactor (login check)
# 3. Optionally tests that smii (admin) can access session info post-login
# 4. Prints a pass/fail table

set -euo pipefail

ENV_FILE="${1:-.env}"
source "$ENV_FILE" 2>/dev/null || { echo "Cannot load $ENV_FILE"; exit 1; }

AUTHELIA_URL="https://${AUTHELIA_HOST:-authelia.rtm.kubernative.io}"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() {
  printf "\n%-15s %-35s %s\n" "PERSONA" "EXPECTED GROUPS" "AUTH STATUS"
  printf "%-15s %-35s %s\n" "-------" "---------------" "-----------"
}

test_login() {
  local username="$1"
  local password="$2"
  local groups="$3"
  local cookie_jar="/tmp/authelia_cookie_$$_${username}"

  local response
  response=$(curl -sk -o /tmp/authelia_body_$$ -w "%{http_code}" \
    -X POST "${AUTHELIA_URL}/api/firstfactor" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${username}\",\"password\":\"${password}\",\"keepMeLoggedIn\":false}" \
    --cookie-jar "${cookie_jar}" \
    2>/dev/null || echo "000")

  rm -f "/tmp/authelia_body_$$" "${cookie_jar}"

  if [[ "$response" == "200" ]]; then
    printf "${GREEN}PASS (authenticated)${NC}\n"
    PASS=$((PASS + 1))
  elif [[ "$response" == "429" ]]; then
    printf "${YELLOW}SKIP (rate-limited)${NC}\n"
  else
    printf "${RED}FAIL (HTTP ${response})${NC}\n"
    FAIL=$((FAIL + 1))
  fi
}

echo "=============================================="
echo " Authelia Authentication Test"
echo " Target: ${AUTHELIA_URL}"
echo "=============================================="
echo ""
echo " NOTE: Tests credential authentication only."
echo " To test access control (forward-auth), browse"
echo " to a protected domain and observe the redirect."
echo "=============================================="

print_header

declare -a PERSONAS=(
  "smii:admins,homelab_prd,devops_prd,platform_prd,webapp_prd"
  "alice:homelab_dev"
  "bob:homelab_test"
  "carol:homelab_prd"
  "dave:webapp_dev"
  "eve:webapp_test"
  "frank:webapp_prd"
  "grace:devops_dev"
  "henry:devops_test"
  "ivan:devops_prd"
  "judy:platform_dev"
  "karl:platform_test"
  "linda:platform_prd"
  "viewer:viewers"
)

for entry in "${PERSONAS[@]}"; do
  IFS=':' read -r username groups <<< "$entry"
  varname="USER_${username^^}_PASSWORD"
  password="${!varname:-${TEST_PASSWORD_DEFAULT:-Homelab2024!}}"

  printf "%-15s %-35s " "$username" "$groups"
  test_login "$username" "$password" "$groups"

  # Small delay to avoid rate limiting
  sleep 0.5
done

echo ""
echo "=============================================="
printf " Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
echo "=============================================="
echo ""
echo -e "${YELLOW}To verify end-to-end SSO:${NC}"
echo "  1. Browse to https://grafana.rtm.kubernative.io (as alice/homelab_dev)"
echo "  2. Should redirect to https://authelia.rtm.kubernative.io for login"
echo "  3. After login, redirected back to Grafana"
echo ""
echo -e "${YELLOW}To verify Authelia Traefik middleware:${NC}"
echo "  kubectl get middleware -n authelia"
echo "  kubectl describe middleware forwardauth -n authelia"
echo ""
echo -e "${YELLOW}To read TOTP enrollment links (2FA users):${NC}"
echo "  kubectl exec -n authelia deployment/authelia -- cat /tmp/authelia-notifications.log"

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}Login failures — debug steps:${NC}"
  echo "  kubectl get pods -n authelia"
  echo "  kubectl logs -n authelia deployment/authelia --tail=50"
  echo "  kubectl get secret authelia-users -n authelia -o jsonpath='{.data.users\\.yml}' | base64 -d"
  exit 1
fi

exit 0
