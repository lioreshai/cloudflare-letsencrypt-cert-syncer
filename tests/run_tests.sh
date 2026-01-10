#!/bin/bash
#
# Integration tests for cert-push.sh MikroTik handler
#
# Tests the ACTUAL push_mikrotik() function against a mock SSH server.
# The mock simulates MikroTik RouterOS command responses.
#

set -euo pipefail

cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DOMAIN="test.example.com"
MOCK_HOST="127.0.0.1"
MOCK_PORT="2222"
MOCK_USER="cert-push"

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------

pass() { echo -e "\033[32m[PASS]\033[0m $1"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $1"; exit 1; }
info() { echo -e "\033[33m[INFO]\033[0m $1"; }

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
    info "Waiting for SSH..."
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

setup_env() {
    export CERT_BASE="$(pwd)/tmp/certs"
    export LOG_FILE="$(pwd)/tmp/test.log"
    export P12_PASS="test-pass"
    export SSH_OPTS="-p $MOCK_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
    export SCP_OPTS="-P $MOCK_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
}

source_cert_push() {
    source ../cert-push.sh
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test_fresh_push() {
    info "TEST: Fresh push (no existing cert)"

    setup_env
    source_cert_push

    # Clear any existing cert
    mock_ssh "/certificate remove [find where common-name=$DOMAIN]" 2>/dev/null || true

    # Call the actual push_mikrotik function
    local output=$(push_mikrotik "$DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1)

    echo "$output" | grep -q "No existing certificate" || fail "Should detect no existing cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    # Verify cert exists on device
    local fp=$(mock_ssh ":put [/certificate get [find where common-name=$DOMAIN] fingerprint]" 2>/dev/null)
    [[ -n "$fp" ]] || fail "Certificate should exist on device"

    pass "Fresh push works"
}

test_skip_unchanged() {
    info "TEST: Skip unchanged cert"

    setup_env
    source_cert_push

    # Push same cert again
    local output=$(push_mikrotik "$DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1)

    echo "$output" | grep -q "unchanged, skipping" || fail "Should skip unchanged cert"

    pass "Skips unchanged certificate"
}

test_push_changed() {
    info "TEST: Push changed cert"

    # Generate new certificate (different fingerprint)
    openssl genrsa -out tmp/certs/$DOMAIN/$DOMAIN.key 2048 2>/dev/null
    openssl req -new -x509 -key tmp/certs/$DOMAIN/$DOMAIN.key \
        -out tmp/certs/$DOMAIN/$DOMAIN.crt -days 30 -subj "/CN=$DOMAIN" 2>/dev/null

    setup_env
    source_cert_push

    local output=$(push_mikrotik "$DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1)

    echo "$output" | grep -q "changed, pushing" || fail "Should detect changed cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    pass "Pushes changed certificate"
}

test_missing_files() {
    info "TEST: Handle missing cert files"

    setup_env
    source_cert_push

    local output=$(push_mikrotik "nonexistent.example.com" "$MOCK_HOST" "$MOCK_USER" 2>&1) || true

    echo "$output" | grep -q "Certificate files not found" || fail "Should report missing files"

    pass "Reports missing certificate files"
}

test_pkcs12_format() {
    info "TEST: PKCS12 uses MikroTik-compatible legacy encryption"

    # Create PKCS12 using same method as the script
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -inkey tmp/certs/$DOMAIN/$DOMAIN.key -in tmp/certs/$DOMAIN/$DOMAIN.crt \
        -out tmp/test.p12 -passout "pass:test-pass" 2>/dev/null

    # Verify format uses legacy encryption
    local info=$(openssl pkcs12 -in tmp/test.p12 -info -passin "pass:test-pass" -noout 2>&1)
    echo "$info" | grep -qi "sha1\|3des" || fail "Should use legacy encryption"

    # Verify contents
    local contents=$(openssl pkcs12 -in tmp/test.p12 -passin "pass:test-pass" -passout "pass:x" 2>/dev/null)
    echo "$contents" | grep -q "BEGIN CERTIFICATE" || fail "Should contain certificate"
    echo "$contents" | grep -q "PRIVATE KEY" || fail "Should contain private key"

    rm -f tmp/test.p12
    pass "PKCS12 format is MikroTik-compatible"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

echo "=========================================="
echo "Integration Tests: MikroTik Handler"
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
