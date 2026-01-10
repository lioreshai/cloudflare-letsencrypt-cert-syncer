#!/bin/bash
#
# pfSense certificate push handler
# Sourced by cert-push.sh - do not run directly
#
# Imports Let's Encrypt certificate into pfSense and configures webConfigurator
# Uses PHP API via SSH to update pfSense config

# Get current certificate fingerprint from pfSense
get_pfsense_fingerprint() {
    local host="$1"
    local user="$2"
    local domain="$3"

    # Extract cert from config.xml by description, decode base64, get fingerprint
    local fingerprint
    fingerprint=$(ssh $SSH_OPTS "${user}@${host}" "php -r '
        require_once(\"globals.inc\");
        require_once(\"config.inc\");
        \$certs = config_get_path(\"cert\", []);
        foreach (\$certs as \$cert) {
            if (\$cert[\"descr\"] === \"$domain\") {
                echo base64_decode(\$cert[\"crt\"]);
                break;
            }
        }
    ' 2>/dev/null" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')

    echo "$fingerprint"
}

# Push certificate to pfSense
push_pfsense() {
    local domain="$1"
    local host="$2"
    local user="${3:-root}"

    local cert_dir="$CERT_BASE/$domain"
    local cert_file="$cert_dir/$domain.crt"
    local key_file="$cert_dir/$domain.key"

    # Check if cert exists
    check_cert_exists "$domain" || return 1

    # Get fingerprints
    local new_fingerprint
    new_fingerprint=$(get_cert_fingerprint "$cert_file")

    log "Processing $domain -> $host [pfsense] (user: $user)"
    log "  New cert fingerprint: $new_fingerprint"

    local current_fingerprint
    current_fingerprint=$(get_pfsense_fingerprint "$host" "$user" "$domain")

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

    # Upload cert and key to pfSense
    log "  Uploading certificate files..."
    scp $SCP_OPTS "$cert_file" "${user}@${host}:/tmp/cert.crt" || {
        log "ERROR: Failed to upload certificate"
        return 1
    }
    scp $SCP_OPTS "$key_file" "${user}@${host}:/tmp/cert.key" || {
        log "ERROR: Failed to upload key"
        ssh $SSH_OPTS "${user}@${host}" "rm -f /tmp/cert.crt"
        return 1
    }

    # Create and upload PHP import script
    local php_script=$(cat <<'PHPEOF'
<?php
require_once("globals.inc");
require_once("config.inc");
require_once("certs.inc");

$domain = $argv[1];
$crt_str = file_get_contents("/tmp/cert.crt");
$key_str = file_get_contents("/tmp/cert.key");

if (!$crt_str || !$key_str) {
    echo "ERROR: Could not read cert/key files\n";
    exit(1);
}

// Find existing cert by description
$certs = config_get_path("cert", []);
$found_idx = -1;
foreach ($certs as $idx => $cert) {
    if ($cert["descr"] === $domain) {
        $found_idx = $idx;
        break;
    }
}

if ($found_idx >= 0) {
    // Update existing cert
    echo "Updating existing certificate...\n";
    $cert_entry = $certs[$found_idx];
    cert_import($cert_entry, $crt_str, $key_str);
    $certs[$found_idx] = $cert_entry;
    config_set_path("cert", $certs);
    $refid = $cert_entry["refid"];
} else {
    // Create new cert entry
    echo "Creating new certificate entry...\n";
    $cert_entry = array();
    $cert_entry["refid"] = uniqid();
    $cert_entry["descr"] = $domain;
    $cert_entry["type"] = "server";
    cert_import($cert_entry, $crt_str, $key_str);
    $certs[] = $cert_entry;
    config_set_path("cert", $certs);
    $refid = $cert_entry["refid"];
}

// Update webConfigurator to use this cert
config_set_path("system/webgui/ssl-certref", $refid);

// Save config
write_config("Imported Let's Encrypt certificate for " . $domain);

echo "Certificate imported successfully. RefID: $refid\n";

// Cleanup temp files
unlink("/tmp/cert.crt");
unlink("/tmp/cert.key");
unlink("/tmp/import_cert.php");
?>
PHPEOF
)

    echo "$php_script" | ssh $SSH_OPTS "${user}@${host}" "cat > /tmp/import_cert.php"

    # Run the import script
    log "  Importing certificate into pfSense..."
    local import_result
    import_result=$(ssh $SSH_OPTS "${user}@${host}" "php /tmp/import_cert.php '$domain'" 2>&1)

    echo "$import_result" | while read -r line; do log "    $line"; done

    if echo "$import_result" | grep -q "ERROR"; then
        log "ERROR: Certificate import failed"
        return 1
    fi

    # Restart webConfigurator to apply new cert
    log "  Restarting webConfigurator..."
    ssh $SSH_OPTS "${user}@${host}" "/etc/rc.restart_webgui" 2>&1 | \
        grep -v "^$" | while read -r line; do log "    $line"; done

    log "  Done! pfSense webConfigurator updated with new certificate"
    return 0
}
