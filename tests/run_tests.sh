#!/bin/bash
#
# Integration tests for mikrotik-cert-push.sh
#
# Tests the push_cert() function against a mock MikroTik SSH server.
# The mock accepts SSH commands and simulates certificate storage.
#

set -euo pipefail

cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DOMAIN="test.example.com"
P12_PASS="test-pass"
MOCK_PORT="2222"

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------

pass() { echo -e "\033[32m[PASS]\033[0m $1"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $1"; exit 1; }
info() { echo -e "\033[33m[INFO]\033[0m $1"; }

# SSH to mock MikroTik
mock_ssh() {
    ssh -p $MOCK_PORT -i tmp/test_key \
        -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        cert-push@127.0.0.1 "$@"
}

# SCP to mock MikroTik
mock_scp() {
    scp -P $MOCK_PORT -i tmp/test_key \
        -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        "$@"
}

# -----------------------------------------------------------------------------
# Setup and teardown
# -----------------------------------------------------------------------------

setup() {
    info "Setting up test environment"

    mkdir -p tmp/certs/$DOMAIN mock-mikrotik/state

    # Generate SSH key for tests
    [[ -f tmp/test_key ]] || ssh-keygen -t ed25519 -f tmp/test_key -N "" -q
    cp tmp/test_key.pub mock-mikrotik/state/authorized_keys

    # Generate test certificate
    info "Generating test certificate"
    openssl genrsa -out tmp/certs/$DOMAIN/$DOMAIN.key 2048 2>/dev/null
    openssl req -new -x509 -key tmp/certs/$DOMAIN/$DOMAIN.key \
        -out tmp/certs/$DOMAIN/$DOMAIN.crt -days 30 -subj "/CN=$DOMAIN" 2>/dev/null

    # Start mock MikroTik
    info "Starting mock MikroTik"
    docker compose -f docker-compose.test.yml up -d --build --quiet-pull 2>/dev/null

    # Wait for SSH
    for i in {1..30}; do
        mock_ssh "echo ready" 2>/dev/null && break
        sleep 1
    done
}

cleanup() {
    info "Cleaning up"
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
    rm -rf tmp mock-mikrotik/state/authorized_keys 2>/dev/null || true
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# The function under test - extracted from mikrotik-cert-push.sh
# -----------------------------------------------------------------------------

push_cert() {
    local domain="$1"
    local host="$2"
    local user="${3:-cert-push}"
    local cert_dir="tmp/certs/$domain"

    # Check cert exists
    [[ -f "$cert_dir/$domain.crt" && -f "$cert_dir/$domain.key" ]] || {
        echo "ERROR: Certificate files not found for $domain"
        return 1
    }

    # Get local fingerprint
    local new_fp=$(openssl x509 -in "$cert_dir/$domain.crt" -noout -fingerprint -sha256 | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    echo "Processing $domain -> $host"
    echo "  Local fingerprint: $new_fp"

    # Get remote fingerprint
    local current_fp=$(mock_ssh ":put [/certificate get [find where common-name=$domain] fingerprint]" 2>/dev/null || true)
    current_fp=$(echo "$current_fp" | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')

    if [[ -n "$current_fp" ]]; then
        echo "  Remote fingerprint: $current_fp"
        if [[ "$new_fp" == "$current_fp" ]]; then
            echo "  Certificate unchanged, skipping"
            return 0
        fi
        echo "  Certificate changed, pushing..."
    else
        echo "  No certificate on device, pushing..."
    fi

    # Create PKCS12 bundle (legacy encryption for MikroTik)
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -inkey "$cert_dir/$domain.key" -in "$cert_dir/$domain.crt" \
        -out "tmp/$domain.p12" -passout "pass:$P12_PASS"

    # Upload and import
    mock_scp "tmp/$domain.p12" "cert-push@127.0.0.1:$domain.p12"
    mock_ssh "/certificate remove [find where common-name=$domain]" 2>/dev/null || true
    mock_ssh "/certificate import file-name=$domain.p12 passphrase=$P12_PASS"
    mock_ssh "/ip service set www-ssl certificate=$domain.p12_0 disabled=no"
    mock_ssh "/file remove \"$domain.p12\"" 2>/dev/null || true

    rm -f "tmp/$domain.p12"
    echo "  Done"
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test_fresh_push() {
    info "TEST: Fresh push (no existing cert)"

    # Clear any existing cert
    mock_ssh "/certificate remove [find where common-name=$DOMAIN]" 2>/dev/null || true

    # Push certificate
    local output=$(push_cert "$DOMAIN" "127.0.0.1" 2>&1)

    echo "$output" | grep -q "No certificate on device" || fail "Should detect no existing cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    # Verify cert exists on device
    local fp=$(mock_ssh ":put [/certificate get [find where common-name=$DOMAIN] fingerprint]" 2>/dev/null)
    [[ -n "$fp" ]] || fail "Certificate should exist on device"

    pass "Fresh push works"
}

test_skip_unchanged() {
    info "TEST: Skip unchanged cert"

    # Push same cert again
    local output=$(push_cert "$DOMAIN" "127.0.0.1" 2>&1)

    echo "$output" | grep -q "unchanged, skipping" || fail "Should skip unchanged cert"

    pass "Skips unchanged certificate"
}

test_push_changed() {
    info "TEST: Push changed cert"

    # Generate new certificate (different key = different fingerprint)
    openssl genrsa -out tmp/certs/$DOMAIN/$DOMAIN.key 2048 2>/dev/null
    openssl req -new -x509 -key tmp/certs/$DOMAIN/$DOMAIN.key \
        -out tmp/certs/$DOMAIN/$DOMAIN.crt -days 30 -subj "/CN=$DOMAIN" 2>/dev/null

    # Push new cert
    local output=$(push_cert "$DOMAIN" "127.0.0.1" 2>&1)

    echo "$output" | grep -q "changed, pushing" || fail "Should detect changed cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    pass "Pushes changed certificate"
}

test_missing_files() {
    info "TEST: Handle missing cert files"

    local output=$(push_cert "nonexistent.example.com" "127.0.0.1" 2>&1) || true

    echo "$output" | grep -q "Certificate files not found" || fail "Should report missing files"

    pass "Reports missing certificate files"
}

test_pkcs12_format() {
    info "TEST: PKCS12 format is MikroTik-compatible"

    # Create PKCS12 with legacy encryption
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -inkey tmp/certs/$DOMAIN/$DOMAIN.key -in tmp/certs/$DOMAIN/$DOMAIN.crt \
        -out tmp/test.p12 -passout "pass:$P12_PASS" 2>/dev/null

    # Verify format
    local info=$(openssl pkcs12 -in tmp/test.p12 -info -passin "pass:$P12_PASS" -noout 2>&1)
    echo "$info" | grep -qi "sha1\|3des" || fail "Should use legacy encryption"

    # Verify contents
    local contents=$(openssl pkcs12 -in tmp/test.p12 -passin "pass:$P12_PASS" -passout "pass:x" 2>/dev/null)
    echo "$contents" | grep -q "BEGIN CERTIFICATE" || fail "Should contain certificate"
    echo "$contents" | grep -q "PRIVATE KEY" || fail "Should contain private key"

    rm -f tmp/test.p12
    pass "PKCS12 uses MikroTik-compatible legacy encryption"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

echo "=========================================="
echo "Integration Tests: mikrotik-cert-push.sh"
echo "=========================================="

setup

test_fresh_push
test_skip_unchanged
test_push_changed
test_missing_files
test_pkcs12_format

echo
echo "=========================================="
echo -e "\033[32mAll tests passed\033[0m"
echo "=========================================="
