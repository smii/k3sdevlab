#!/usr/bin/env bash
# =============================================================================
# trust-ca.sh — Install the Vagrant CA certificate on your HOST machine
# =============================================================================
# Run this once after `vagrant up` to eliminate browser security warnings
# for all *.nip.io services.  Requires the VM to be running.
#
# Usage:  bash vagrant/trust-ca.sh
# =============================================================================
set -euo pipefail

CA_FILE="$(pwd)/.vagrant-ca.crt"

echo "▶  Fetching CA certificate from Vagrant VM..."
vagrant ssh -c "sudo cat /etc/ssl/vagrant-ca/ca.crt" > "${CA_FILE}" 2>/dev/null \
  || { echo "✗  Could not reach the VM. Is it running? (vagrant up)"; exit 1; }

echo "✓  CA certificate saved to ${CA_FILE}"

OS="$(uname -s)"
case "${OS}" in
  Darwin)
    echo "▶  Installing on macOS..."
    sudo security add-trusted-cert \
      -d -r trustRoot \
      -k /Library/Keychains/System.keychain \
      "${CA_FILE}"
    echo "✓  CA trusted. Restart Chrome/Firefox/Safari for changes to take effect."
    ;;

  Linux)
    echo "▶  Installing on Linux..."
    DEST=""
    if [ -d /usr/local/share/ca-certificates ]; then
      # Debian / Ubuntu
      DEST="/usr/local/share/ca-certificates/k3sdevlab-vagrant.crt"
      sudo cp "${CA_FILE}" "${DEST}"
      sudo update-ca-certificates
    elif [ -d /etc/pki/ca-trust/source/anchors ]; then
      # RHEL / Fedora / CentOS
      DEST="/etc/pki/ca-trust/source/anchors/k3sdevlab-vagrant.crt"
      sudo cp "${CA_FILE}" "${DEST}"
      sudo update-ca-trust extract
    else
      echo "⚠  Could not auto-detect CA store. Copy ${CA_FILE} to your system trust store manually."
      exit 1
    fi
    echo "✓  CA trusted at ${DEST}. Restart your browser."
    ;;

  MINGW*|MSYS*|CYGWIN*)
    echo "▶  Windows detected."
    echo ""
    echo "  Option A — PowerShell (run as Administrator):"
    echo "    Import-Certificate -FilePath '${CA_FILE}' -CertStoreLocation Cert:\\LocalMachine\\Root"
    echo ""
    echo "  Option B — GUI:"
    echo "  1. Double-click ${CA_FILE}"
    echo "  2. Click 'Install Certificate'"
    echo "  3. Choose 'Local Machine' → 'Trusted Root Certification Authorities'"
    echo "  4. Restart your browser."
    ;;

  *)
    echo "⚠  Unknown OS '${OS}'. Install ${CA_FILE} manually in your system trust store."
    ;;
esac

# Optionally show the cert details for verification
echo ""
echo "Certificate details:"
openssl x509 -in "${CA_FILE}" -noout -subject -issuer -dates 2>/dev/null || true
