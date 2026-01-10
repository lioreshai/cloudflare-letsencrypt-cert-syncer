#!/bin/bash
#
# cert-push.sh
# Push Let's Encrypt certificates from Caddy to various target devices
#
# Supports multiple target types:
#   - mikrotik: RouterOS devices (PKCS12 format)
#   - pfsense: pfSense firewalls (PHP config API)
#   - qnap: QNAP NAS devices (combined PEM format)
#
# Features:
# - Compares fingerprints to only push when certificate changes
# - Modular handlers for different device types
# - Configurable via environment variables
#
# Requirements:
# - Caddy with certificates in standard ACME directory structure
# - SSH key authentication to target devices
# - openssl, scp, ssh
#
# Environment variables:
#   CERT_BASE  - Path to Caddy certificate storage
#   LOG_FILE   - Log file location
#   P12_PASS   - PKCS12 password for MikroTik (used during transport)
#   SUDO_PASS  - Sudo password for QNAP targets
#   SSH_OPTS   - SSH options (default: strict host key checking disabled)
#   SCP_OPTS   - SCP options (default: same as SSH_OPTS with -P for port)
#
# Usage:
#   ./cert-push.sh
#
# Cron example (daily at 4 AM):
#   0 4 * * * root /path/to/cert-push.sh >> /var/log/cert-push.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#######################################
# CONFIGURATION
# Override via environment variables or edit defaults below
#######################################

# Path to Caddy's certificate storage
CERT_BASE="${CERT_BASE:-/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory}"

# Log file location
LOG_FILE="${LOG_FILE:-/var/log/cert-push.log}"

# PKCS12 password for MikroTik (used only during transport)
P12_PASS="${P12_PASS:-change-this-password}"

# SSH/SCP options
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10}"
SCP_OPTS="${SCP_OPTS:-$SSH_OPTS}"

#######################################
# COMMON FUNCTIONS
#######################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Get certificate fingerprint from file
get_cert_fingerprint() {
    local cert_file="$1"
    openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}

# Check if certificate files exist
check_cert_exists() {
    local domain="$1"
    local cert_dir="$CERT_BASE/$domain"
    local cert_file="$cert_dir/$domain.crt"
    local key_file="$cert_dir/$domain.key"

    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        log "ERROR: Certificate files not found for $domain"
        log "  Expected: $cert_file"
        log "  Expected: $key_file"
        return 1
    fi
    return 0
}

#######################################
# SOURCE HANDLERS
#######################################

source "$SCRIPT_DIR/lib/mikrotik.sh"
source "$SCRIPT_DIR/lib/pfsense.sh"
source "$SCRIPT_DIR/lib/qnap.sh"

#######################################
# MAIN DISPATCH FUNCTION
#######################################

# Push certificate to a device
# Usage: push_cert <type> <domain> <host> [user]
push_cert() {
    local target_type="$1"
    local domain="$2"
    local host="$3"
    local user="${4:-}"

    case "$target_type" in
        mikrotik)
            push_mikrotik "$domain" "$host" "${user:-cert-push}"
            ;;
        pfsense)
            push_pfsense "$domain" "$host" "${user:-root}"
            ;;
        qnap)
            push_qnap "$domain" "$host" "${user:-admin}"
            ;;
        *)
            log "ERROR: Unknown target type: $target_type"
            return 1
            ;;
    esac
}

#######################################
# MAIN
# Only runs when executed directly, not when sourced
#######################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log "=== Certificate Push Started ==="

    # Configure your devices below
    # Format: push_cert <type> <domain> <host> [user]

    # Example MikroTik devices:
    # push_cert mikrotik "router.example.com" "192.168.1.1" "cert-push"
    # push_cert mikrotik "switch.example.com" "192.168.1.2" "cert-push"

    # Example pfSense firewall:
    # push_cert pfsense "firewall.example.com" "192.168.1.254" "root"

    # Example QNAP NAS (requires SUDO_PASS environment variable):
    # push_cert qnap "nas.example.com" "192.168.1.100" "admin"

    # Remove this line after configuring your devices:
    log "WARNING: No devices configured! Edit the script to add your devices."

    log "=== Certificate Push Completed ==="
fi
