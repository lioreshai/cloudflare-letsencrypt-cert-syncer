#!/bin/bash
#
# mikrotik-cert-push.sh
# Push Let's Encrypt certificates from Caddy to MikroTik devices
#
# Features:
# - Compares fingerprints to only push when certificate changes
# - Uses PKCS12 format for proper private key association
# - Legacy encryption for MikroTik compatibility
# - Supports multiple devices
#
# Requirements:
# - Caddy with certificates in standard ACME directory structure
# - SSH key authentication to MikroTik
# - MikroTik user with ssh,ftp,read,write permissions
# - openssl, scp, ssh
#
# Usage:
#   ./mikrotik-cert-push.sh
#
# Cron example (daily at 4 AM):
#   0 4 * * * root /path/to/mikrotik-cert-push.sh >> /var/log/mikrotik-cert-push.log 2>&1

set -euo pipefail

#######################################
# CONFIGURATION - Edit these values
#######################################

# Path to Caddy's certificate storage
# Default Docker path: /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory
CERT_BASE="/path/to/caddy/data/certificates/acme-v02.api.letsencrypt.org-directory"

# Log file location
LOG_FILE="/var/log/mikrotik-cert-push.log"

# PKCS12 password (used only during transport)
P12_PASS="change-this-password"

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10"

#######################################
# END CONFIGURATION
#######################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

push_cert() {
    local domain="$1"
    local mikrotik_host="$2"
    local mikrotik_user="${3:-cert-push}"

    local cert_dir="$CERT_BASE/$domain"
    local cert_file="$cert_dir/$domain.crt"
    local key_file="$cert_dir/$domain.key"
    local p12_file="/tmp/${domain}.p12"

    # Check if cert exists
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        log "ERROR: Certificate files not found for $domain"
        log "  Expected: $cert_file"
        log "  Expected: $key_file"
        return 1
    fi

    # Get new cert fingerprint (lowercase, no colons for comparison)
    local new_fingerprint
    new_fingerprint=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    log "Processing $domain -> $mikrotik_host (user: $mikrotik_user)"
    log "  New cert fingerprint: $new_fingerprint"

    # Get current cert fingerprint from MikroTik (if exists)
    local current_fingerprint
    current_fingerprint=$(ssh $SSH_OPTS "${mikrotik_user}@${mikrotik_host}" \
        ":put [/certificate get [find where common-name=$domain] fingerprint]" 2>/dev/null || echo "")

    # Normalize fingerprint format (remove colons, lowercase)
    current_fingerprint=$(echo "$current_fingerprint" | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')

    if [[ -n "$current_fingerprint" ]]; then
        log "  Current cert fingerprint: $current_fingerprint"

        if [[ "$new_fingerprint" == "$current_fingerprint" ]]; then
            log "  Certificate unchanged, skipping push"
            return 0
        fi
        log "  Certificate changed, pushing new cert..."
    else
        log "  No existing certificate found, pushing new cert..."
    fi

    # Create PKCS12 bundle with legacy encryption for MikroTik compatibility
    # MikroTik doesn't support modern PKCS12 encryption algorithms
    log "  Creating PKCS12 bundle..."
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -out "$p12_file" \
        -inkey "$key_file" \
        -in "$cert_file" \
        -passout "pass:$P12_PASS" || {
        log "ERROR: Failed to create PKCS12 bundle"
        return 1
    }

    # Upload PKCS12 to MikroTik
    log "  Uploading PKCS12 bundle..."
    scp $SSH_OPTS "$p12_file" "${mikrotik_user}@${mikrotik_host}:${domain}.p12" || {
        log "ERROR: Failed to upload PKCS12"
        rm -f "$p12_file"
        return 1
    }
    rm -f "$p12_file"

    # Remove old certificate if exists (ignore errors if doesn't exist)
    log "  Removing old certificate (if exists)..."
    ssh $SSH_OPTS "${mikrotik_user}@${mikrotik_host}" \
        "/certificate remove [find where common-name=$domain]" 2>/dev/null || true

    # Import PKCS12 (includes private key)
    log "  Importing PKCS12 certificate..."
    local import_output
    import_output=$(ssh $SSH_OPTS "${mikrotik_user}@${mikrotik_host}" \
        "/certificate import file-name=${domain}.p12 passphrase=$P12_PASS" 2>&1)
    echo "$import_output" | while read -r line; do log "    $line"; done

    # Verify import succeeded (should have private-keys-imported: 1)
    if ! echo "$import_output" | grep -q "private-keys-imported: 1"; then
        log "WARNING: Private key may not have been imported correctly"
    fi

    # Certificate name follows MikroTik convention for PKCS12: filename_0
    local cert_name="${domain}.p12_0"
    log "  Imported as: $cert_name"

    # Configure www-ssl service
    log "  Configuring www-ssl service..."
    ssh $SSH_OPTS "${mikrotik_user}@${mikrotik_host}" \
        "/ip service set www-ssl certificate=\"$cert_name\" disabled=no"

    # Cleanup uploaded file from MikroTik
    log "  Cleaning up temporary files..."
    ssh $SSH_OPTS "${mikrotik_user}@${mikrotik_host}" \
        "/file remove \"${domain}.p12\"" 2>/dev/null || true

    log "  Done! www-ssl enabled with certificate $cert_name"
    return 0
}

#######################################
# MAIN - Configure your devices here
#######################################

log "=== MikroTik Certificate Push Started ==="

# Push to each MikroTik device
# Format: push_cert "domain" "ip-address" "username"

# Example devices - uncomment and modify as needed:
# push_cert "router.example.com" "192.168.1.1" "cert-push"
# push_cert "switch.example.com" "192.168.1.2" "cert-push"
# push_cert "ap.example.com" "192.168.1.3" "cert-push"

# Remove this line after configuring your devices:
log "WARNING: No devices configured! Edit the script to add your MikroTik devices."

log "=== MikroTik Certificate Push Completed ==="
