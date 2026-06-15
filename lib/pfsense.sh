#!/bin/bash
#
# pfSense certificate push handler
# Sourced by cert-push.sh - do not run directly
#
# Imports a Let's Encrypt certificate into pfSense and points the
# webConfigurator at it, via the pfSense PHP API over SSH.
#
# IMPORTANT: this handler uses a SINGLE SSH connection per run.
#   1. pfSense's sshguard treats a burst of SSH/scp connections (or repeated
#      auth failures) from one source as a brute-force attack and blocks that
#      source IP in the `sshguard` pf table — after which every push silently
#      times out. The previous multi-connection version (fingerprint check + 2x
#      scp + upload php + run php + restart = ~6 connections) reliably tripped
#      this. Keep everything in one ssh session below; do NOT split it.
#   2. The SSH key you use must be authorized on pfSense (System > User Manager >
#      admin > Authorized SSH Keys). A missing key fails as
#      "Permission denied (publickey)" on every run, which also feeds sshguard.

# Push certificate to pfSense (single SSH connection)
push_pfsense() {
    local domain="$1"
    local host="$2"
    local user="${3:-root}"

    local cert_dir="$CERT_BASE/$domain"
    local cert_file="$cert_dir/$domain.crt"
    local key_file="$cert_dir/$domain.key"

    check_cert_exists "$domain" || return 1

    log "Processing $domain -> $host [pfsense] (user: $user)"
    log "  New cert fingerprint: $(get_cert_fingerprint "$cert_file")"

    # PHP importer: compares the uploaded cert against the configured one and only
    # imports + restarts webConfigurator when it actually changed.
    local php_script
    php_script=$(cat <<'PHPEOF'
<?php
require_once("globals.inc");
require_once("config.inc");
require_once("certs.inc");

$domain = $argv[1];
$crt_str = file_get_contents("/tmp/cert.crt");
$key_str = file_get_contents("/tmp/cert.key");
if (!$crt_str || !$key_str) { echo "ERROR: Could not read cert/key files\n"; exit(1); }

$certs = config_get_path("cert", []);
$found_idx = -1;
foreach ($certs as $idx => $cert) {
    if ($cert["descr"] === $domain) { $found_idx = $idx; break; }
}

// Change-detection: skip import + webgui restart if the cert is already current.
if ($found_idx >= 0) {
    $old_crt = base64_decode($certs[$found_idx]["crt"]);
    $fp_old = @openssl_x509_fingerprint($old_crt, "sha256");
    $fp_new = @openssl_x509_fingerprint($crt_str, "sha256");
    if ($fp_old && $fp_new && $fp_old === $fp_new) {
        echo "Certificate unchanged, skipping\n";
        exit(0);
    }
}

if ($found_idx >= 0) {
    echo "Updating existing certificate...\n";
    $cert_entry = $certs[$found_idx];
    cert_import($cert_entry, $crt_str, $key_str);
    $certs[$found_idx] = $cert_entry;
    config_set_path("cert", $certs);
    $refid = $cert_entry["refid"];
} else {
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

config_set_path("system/webgui/ssl-certref", $refid);
write_config("Imported Let's Encrypt certificate for " . $domain);
echo "Certificate imported successfully. RefID: $refid\n";
echo "Restarting webConfigurator...\n";
mwexec("/etc/rc.restart_webgui");
echo "Done\n";
?>
PHPEOF
)

    local crt_b64 key_b64 php_b64
    crt_b64=$(base64 -w0 "$cert_file")
    key_b64=$(base64 -w0 "$key_file")
    php_b64=$(printf '%s' "$php_script" | base64 -w0)

    log "  Deploying via single SSH session..."
    local result rc
    result=$(ssh $SSH_OPTS "${user}@${host}" "
        umask 077
        printf %s '$crt_b64' | openssl base64 -d -A > /tmp/cert.crt
        printf %s '$key_b64' | openssl base64 -d -A > /tmp/cert.key
        printf %s '$php_b64' | openssl base64 -d -A > /tmp/import_cert.php
        php /tmp/import_cert.php '$domain'
        ret=\$?
        rm -f /tmp/cert.crt /tmp/cert.key /tmp/import_cert.php
        exit \$ret
    " 2>&1)
    rc=$?

    echo "$result" | while read -r line; do [ -n "$line" ] && log "    $line"; done

    if [ $rc -ne 0 ] || echo "$result" | grep -q "ERROR"; then
        log "ERROR: pfSense certificate deploy failed (rc=$rc)"
        return 1
    fi

    log "  Done! pfSense webConfigurator in sync with current certificate"
    return 0
}
