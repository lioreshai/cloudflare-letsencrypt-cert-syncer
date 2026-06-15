#!/bin/bash
#
# QNAP certificate push handler
# Sourced by cert-push.sh - do not run directly
#
# Uses combined PEM format (key + cert)
# Requires SUDO_PASS environment variable for elevated privileges

QNAP_CERT_PATH="${QNAP_CERT_PATH:-/etc/stunnel/stunnel.pem}"

# Get current certificate fingerprint from QNAP
get_qnap_fingerprint() {
    local host="$1"
    local user="$2"

    if [[ -z "${SUDO_PASS:-}" ]]; then
        log "  WARNING: SUDO_PASS not set, cannot check current QNAP certificate"
        echo ""
        return
    fi

    local fingerprint
    fingerprint=$(ssh $SSH_OPTS "${user}@${host}" \
        "echo '$SUDO_PASS' | sudo -S cat $QNAP_CERT_PATH 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null" | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')

    echo "$fingerprint"
}

# Push certificate to QNAP device
push_qnap() {
    local domain="$1"
    local host="$2"
    local user="${3:-admin}"

    local cert_dir="$CERT_BASE/$domain"
    local cert_file="$cert_dir/$domain.crt"
    local key_file="$cert_dir/$domain.key"
    local pem_file="/tmp/${domain}.pem"

    # Check if cert exists
    check_cert_exists "$domain" || return 1

    # Check for sudo password
    if [[ -z "${SUDO_PASS:-}" ]]; then
        log "ERROR: SUDO_PASS environment variable not set for QNAP"
        return 1
    fi

    # Get fingerprints
    local new_fingerprint
    new_fingerprint=$(get_cert_fingerprint "$cert_file")

    log "Processing $domain -> $host [qnap] (user: $user)"
    log "  New cert fingerprint: $new_fingerprint"

    local current_fingerprint
    current_fingerprint=$(get_qnap_fingerprint "$host" "$user")

    if [[ -n "$current_fingerprint" ]]; then
        log "  Current cert fingerprint: $current_fingerprint"

        if [[ "$new_fingerprint" == "$current_fingerprint" ]]; then
            log "  Certificate unchanged, skipping push"
            return 0
        fi
        log "  Certificate changed, pushing new cert..."
    else
        log "  No existing certificate found or unable to read, pushing new cert..."
    fi

    # Create combined PEM (key + cert)
    # QNAP expects: private key, then certificate
    log "  Creating combined PEM bundle..."
    cat "$key_file" "$cert_file" > "$pem_file" || {
        log "ERROR: Failed to create PEM bundle"
        return 1
    }

    # Upload PEM to QNAP user's home (uses SSH key auth)
    log "  Uploading PEM bundle..."
    scp $SCP_OPTS "$pem_file" "${user}@${host}:${domain}.pem" || {
        log "ERROR: Failed to upload PEM"
        rm -f "$pem_file"
        return 1
    }
    rm -f "$pem_file"

    # Backup existing cert and install new one (uses sudo with password)
    log "  Installing certificate (requires sudo)..."
    ssh $SSH_OPTS "${user}@${host}" "
        echo '$SUDO_PASS' | sudo -S cp $QNAP_CERT_PATH ${QNAP_CERT_PATH}.bak 2>/dev/null
        echo '$SUDO_PASS' | sudo -S cp ~/${domain}.pem $QNAP_CERT_PATH
        echo '$SUDO_PASS' | sudo -S chmod 600 $QNAP_CERT_PATH
        echo '$SUDO_PASS' | sudo -S chown admin:administrators $QNAP_CERT_PATH
        rm -f ~/${domain}.pem
    " || {
        log "ERROR: Failed to install certificate"
        return 1
    }

    # Restart the SSL terminator so it reloads the cert from disk.
    #
    # IMPORTANT: on QTS, HTTPS (:443) is terminated by apache_proxys
    # (apache-sys-proxy-ssl.conf), which is managed by /etc/init.d/stunnel.sh —
    # NOT by thttpd. thttpd serves the plain-HTTP backend on localhost. So
    # restarting thttpd updates /etc/stunnel/stunnel.pem on disk but leaves
    # apache_proxys serving the OLD cert from memory, and :443 keeps the stale
    # cert until the next reboot. Restart stunnel.sh to actually reload :443.
    log "  Restarting QNAP SSL proxy (stunnel.sh -> apache_proxys :443)..."
    ssh $SSH_OPTS "${user}@${host}" \
        "echo '$SUDO_PASS' | sudo -S /etc/init.d/stunnel.sh restart" 2>&1 | \
        grep -v "password" | grep -v "Password" | while read -r line; do log "    $line"; done

    log "  Done! QNAP SSL proxy restarted with new certificate"
    return 0
}
