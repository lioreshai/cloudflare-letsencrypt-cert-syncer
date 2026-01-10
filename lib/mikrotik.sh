#!/bin/bash
#
# MikroTik certificate push handler
# Sourced by cert-push.sh - do not run directly
#
# Uses PKCS12 format with legacy encryption for MikroTik compatibility
# MikroTik doesn't support modern PKCS12 encryption algorithms

# Get current certificate fingerprint from MikroTik
get_mikrotik_fingerprint() {
    local host="$1"
    local user="$2"
    local domain="$3"

    local fingerprint
    fingerprint=$(ssh $SSH_OPTS "${user}@${host}" \
        ":put [/certificate get [find where common-name=$domain] fingerprint]" 2>/dev/null || echo "")

    # Normalize: remove colons, lowercase, strip whitespace
    echo "$fingerprint" | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n'
}

# Push certificate to MikroTik device
push_mikrotik() {
    local domain="$1"
    local host="$2"
    local user="${3:-cert-push}"

    local cert_dir="$CERT_BASE/$domain"
    local cert_file="$cert_dir/$domain.crt"
    local key_file="$cert_dir/$domain.key"
    local p12_file="/tmp/${domain}.p12"

    # Check if cert exists
    check_cert_exists "$domain" || return 1

    # Get fingerprints
    local new_fingerprint
    new_fingerprint=$(get_cert_fingerprint "$cert_file")

    log "Processing $domain -> $host [mikrotik] (user: $user)"
    log "  New cert fingerprint: $new_fingerprint"

    local current_fingerprint
    current_fingerprint=$(get_mikrotik_fingerprint "$host" "$user" "$domain")

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

    # Create PKCS12 bundle (legacy encryption for MikroTik compatibility)
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
    scp $SCP_OPTS "$p12_file" "${user}@${host}:${domain}.p12" || {
        log "ERROR: Failed to upload PKCS12"
        rm -f "$p12_file"
        return 1
    }
    rm -f "$p12_file"

    # Remove old certificate if exists
    log "  Removing old certificate (if exists)..."
    ssh $SSH_OPTS "${user}@${host}" "/certificate remove [find where common-name=$domain]" 2>/dev/null || true

    # Import PKCS12 (includes private key)
    log "  Importing PKCS12 certificate..."
    local import_output
    import_output=$(ssh $SSH_OPTS "${user}@${host}" "/certificate import file-name=${domain}.p12 passphrase=$P12_PASS" 2>&1)
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
    ssh $SSH_OPTS "${user}@${host}" "/ip service set www-ssl certificate=\"$cert_name\" disabled=no"

    # Cleanup uploaded file
    log "  Cleaning up temporary files..."
    ssh $SSH_OPTS "${user}@${host}" "/file remove \"${domain}.p12\"" 2>/dev/null || true

    log "  Done! www-ssl enabled with certificate $cert_name"
    return 0
}
