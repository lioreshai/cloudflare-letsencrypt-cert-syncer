#!/bin/bash
#
# Integration tests for mikrotik-cert-push.sh
#
# Tests the ACTUAL push_cert() function against a mock MikroTik SSH server.
# The mock accepts SSH commands and simulates certificate storage.
#

set -euo pipefail

cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DOMAIN="test.example.com"
MOCK_PORT="2222"
MOCK_USER="cert-push"
MOCK_HOST="127.0.0.1"

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------

pass() { echo -e "\033[32m[PASS]\033[0m $1"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $1"; exit 1; }
info() { echo -e "\033[33m[INFO]\033[0m $1"; }

# Direct SSH/SCP to mock (for setup/teardown, not for testing push_cert)
mock_ssh() {
    ssh -p $MOCK_PORT -i tmp/test_key \
        -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        ${MOCK_USER}@${MOCK_HOST} "$@"
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
# Source the ACTUAL script under test
# -----------------------------------------------------------------------------

setup_env_and_source() {
    # Configure environment to use mock MikroTik (must run after setup creates SSH key)
    export CERT_BASE="$(pwd)/tmp/certs"
    export LOG_FILE="$(pwd)/tmp/test.log"
    export P12_PASS="test-pass"
    export SSH_OPTS="-p $MOCK_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
    export SCP_OPTS="-P $MOCK_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"

    # Source the actual script (won't run main due to BASH_SOURCE guard)
    source ../mikrotik-cert-push.sh
}

# -----------------------------------------------------------------------------
# Tests - calling the ACTUAL push_cert() function from mikrotik-cert-push.sh
# -----------------------------------------------------------------------------

test_fresh_push() {
    info "TEST: Fresh push (no existing cert)"

    # Clear any existing cert on mock
    mock_ssh "/certificate remove [find where common-name=$DOMAIN]" 2>/dev/null || true

    # Call the ACTUAL push_cert function from mikrotik-cert-push.sh
    local output=$(push_cert "$DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1)

    echo "$output" | grep -q "No existing certificate" || fail "Should detect no existing cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    # Verify cert exists on device
    local fp=$(mock_ssh ":put [/certificate get [find where common-name=$DOMAIN] fingerprint]" 2>/dev/null)
    [[ -n "$fp" ]] || fail "Certificate should exist on device"

    pass "Fresh push works"
}

test_skip_unchanged() {
    info "TEST: Skip unchanged cert"

    # Call push_cert again with same cert - should skip
    local output=$(push_cert "$DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1)

    echo "$output" | grep -q "unchanged, skipping" || fail "Should skip unchanged cert"

    pass "Skips unchanged certificate"
}

test_push_changed() {
    info "TEST: Push changed cert"

    # Generate new certificate (different key = different fingerprint)
    openssl genrsa -out tmp/certs/$DOMAIN/$DOMAIN.key 2048 2>/dev/null
    openssl req -new -x509 -key tmp/certs/$DOMAIN/$DOMAIN.key \
        -out tmp/certs/$DOMAIN/$DOMAIN.crt -days 30 -subj "/CN=$DOMAIN" 2>/dev/null

    # Call push_cert - should detect change and push
    local output=$(push_cert "$DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1)

    echo "$output" | grep -q "changed, pushing" || fail "Should detect changed cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    pass "Pushes changed certificate"
}

test_missing_files() {
    info "TEST: Handle missing cert files"

    # Call push_cert with non-existent domain
    local output=$(push_cert "nonexistent.example.com" "$MOCK_HOST" "$MOCK_USER" 2>&1) || true

    echo "$output" | grep -q "Certificate files not found" || fail "Should report missing files"

    pass "Reports missing certificate files"
}

test_pkcs12_format() {
    info "TEST: PKCS12 format is MikroTik-compatible"

    # Create PKCS12 using same method as the script
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -inkey tmp/certs/$DOMAIN/$DOMAIN.key -in tmp/certs/$DOMAIN/$DOMAIN.crt \
        -out tmp/test.p12 -passout "pass:$P12_PASS" 2>/dev/null

    # Verify format uses legacy encryption
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
setup_env_and_source  # Source actual script after setup creates SSH key

test_fresh_push
test_skip_unchanged
test_push_changed
test_missing_files
test_pkcs12_format

echo
echo "=========================================="
echo -e "\033[32mAll tests passed\033[0m"
echo "=========================================="
