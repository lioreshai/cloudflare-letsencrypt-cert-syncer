#!/bin/bash
#
# Integration tests for cert-push.sh
#
# Tests the ACTUAL handler functions against mock SSH servers.
# Each mock simulates the target device's command responses.
#

set -euo pipefail

cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DOMAIN="test.example.com"
MOCK_HOST="127.0.0.1"

MIKROTIK_PORT="2222"
MIKROTIK_USER="cert-push"

PFSENSE_PORT="2223"
PFSENSE_USER="root"

QNAP_PORT="2224"
QNAP_USER="qnap"

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------

pass() { echo -e "\033[32m[PASS]\033[0m $1"; }
fail() { echo -e "\033[31m[FAIL]\033[0m $1"; exit 1; }
info() { echo -e "\033[33m[INFO]\033[0m $1"; }

# SSH helpers for direct mock access (setup/teardown)
ssh_mikrotik() {
    ssh -p $MIKROTIK_PORT -i tmp/test_key \
        -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        ${MIKROTIK_USER}@${MOCK_HOST} "$@"
}

ssh_pfsense() {
    ssh -p $PFSENSE_PORT -i tmp/test_key \
        -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        ${PFSENSE_USER}@${MOCK_HOST} "$@"
}

ssh_qnap() {
    ssh -p $QNAP_PORT -i tmp/test_key \
        -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        ${QNAP_USER}@${MOCK_HOST} "$@"
}

# -----------------------------------------------------------------------------
# Setup and teardown
# -----------------------------------------------------------------------------

setup() {
    info "Setting up test environment"

    mkdir -p tmp/certs/$DOMAIN mock-mikrotik/state mock-pfsense/state mock-qnap/state

    # Generate SSH key for tests
    [[ -f tmp/test_key ]] || ssh-keygen -t ed25519 -f tmp/test_key -N "" -q

    # Copy key to all mock state directories
    cp tmp/test_key.pub mock-mikrotik/state/authorized_keys
    cp tmp/test_key.pub mock-pfsense/state/authorized_keys
    cp tmp/test_key.pub mock-qnap/state/authorized_keys

    # Generate test certificate
    info "Generating test certificate"
    openssl genrsa -out tmp/certs/$DOMAIN/$DOMAIN.key 2048 2>/dev/null
    openssl req -new -x509 -key tmp/certs/$DOMAIN/$DOMAIN.key \
        -out tmp/certs/$DOMAIN/$DOMAIN.crt -days 30 -subj "/CN=$DOMAIN" 2>/dev/null

    # Start all mock services
    info "Starting mock services"
    docker compose -f docker-compose.test.yml up -d --build --quiet-pull 2>/dev/null

    # Wait for all SSH services
    info "Waiting for SSH services..."
    for i in {1..30}; do
        ssh_mikrotik "echo ready" 2>/dev/null && \
        ssh_pfsense "echo ready" 2>/dev/null && \
        ssh_qnap "echo ready" 2>/dev/null && break
        sleep 1
    done
}

cleanup() {
    info "Cleaning up"
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
    rm -rf tmp 2>/dev/null || true
    rm -f mock-mikrotik/state/authorized_keys mock-pfsense/state/authorized_keys mock-qnap/state/authorized_keys 2>/dev/null || true
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Source the ACTUAL script under test
# -----------------------------------------------------------------------------

setup_mikrotik_env() {
    export CERT_BASE="$(pwd)/tmp/certs"
    export LOG_FILE="$(pwd)/tmp/test.log"
    export P12_PASS="test-pass"
    export SSH_OPTS="-p $MIKROTIK_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
    export SCP_OPTS="-P $MIKROTIK_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
}

setup_pfsense_env() {
    export CERT_BASE="$(pwd)/tmp/certs"
    export LOG_FILE="$(pwd)/tmp/test.log"
    export SSH_OPTS="-p $PFSENSE_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
    export SCP_OPTS="-P $PFSENSE_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
}

setup_qnap_env() {
    export CERT_BASE="$(pwd)/tmp/certs"
    export LOG_FILE="$(pwd)/tmp/test.log"
    export SUDO_PASS="test-sudo-pass"
    export SSH_OPTS="-p $QNAP_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
    export SCP_OPTS="-P $QNAP_PORT -i $(pwd)/tmp/test_key -o StrictHostKeyChecking=no -o LogLevel=ERROR"
}

# Source the main cert-push.sh (loads all handlers)
source_cert_push() {
    source ../cert-push.sh
}

# -----------------------------------------------------------------------------
# MikroTik Tests
# -----------------------------------------------------------------------------

test_mikrotik_fresh_push() {
    info "TEST [MikroTik]: Fresh push (no existing cert)"

    setup_mikrotik_env
    source_cert_push

    # Clear any existing cert
    ssh_mikrotik "/certificate remove [find where common-name=$DOMAIN]" 2>/dev/null || true

    # Call the actual push_mikrotik function
    local output=$(push_mikrotik "$DOMAIN" "$MOCK_HOST" "$MIKROTIK_USER" 2>&1)

    echo "$output" | grep -q "No existing certificate" || fail "Should detect no existing cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    # Verify cert exists on device
    local fp=$(ssh_mikrotik ":put [/certificate get [find where common-name=$DOMAIN] fingerprint]" 2>/dev/null)
    [[ -n "$fp" ]] || fail "Certificate should exist on device"

    pass "MikroTik fresh push works"
}

test_mikrotik_skip_unchanged() {
    info "TEST [MikroTik]: Skip unchanged cert"

    setup_mikrotik_env
    source_cert_push

    # Push same cert again
    local output=$(push_mikrotik "$DOMAIN" "$MOCK_HOST" "$MIKROTIK_USER" 2>&1)

    echo "$output" | grep -q "unchanged, skipping" || fail "Should skip unchanged cert"

    pass "MikroTik skips unchanged certificate"
}

test_mikrotik_push_changed() {
    info "TEST [MikroTik]: Push changed cert"

    # Generate new certificate
    openssl genrsa -out tmp/certs/$DOMAIN/$DOMAIN.key 2048 2>/dev/null
    openssl req -new -x509 -key tmp/certs/$DOMAIN/$DOMAIN.key \
        -out tmp/certs/$DOMAIN/$DOMAIN.crt -days 30 -subj "/CN=$DOMAIN" 2>/dev/null

    setup_mikrotik_env
    source_cert_push

    local output=$(push_mikrotik "$DOMAIN" "$MOCK_HOST" "$MIKROTIK_USER" 2>&1)

    echo "$output" | grep -q "changed, pushing" || fail "Should detect changed cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    pass "MikroTik pushes changed certificate"
}

# -----------------------------------------------------------------------------
# pfSense Tests
# -----------------------------------------------------------------------------

test_pfsense_fresh_push() {
    info "TEST [pfSense]: Fresh push (no existing cert)"

    setup_pfsense_env
    source_cert_push

    # Call the actual push_pfsense function
    local output=$(push_pfsense "$DOMAIN" "$MOCK_HOST" "$PFSENSE_USER" 2>&1)

    echo "$output" | grep -q "No existing certificate" || fail "Should detect no existing cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    pass "pfSense fresh push works"
}

test_pfsense_skip_unchanged() {
    info "TEST [pfSense]: Skip unchanged cert"

    setup_pfsense_env
    source_cert_push

    # Push same cert again
    local output=$(push_pfsense "$DOMAIN" "$MOCK_HOST" "$PFSENSE_USER" 2>&1)

    echo "$output" | grep -q "unchanged, skipping" || fail "Should skip unchanged cert"

    pass "pfSense skips unchanged certificate"
}

# -----------------------------------------------------------------------------
# QNAP Tests
# -----------------------------------------------------------------------------

test_qnap_fresh_push() {
    info "TEST [QNAP]: Fresh push (no existing cert)"

    setup_qnap_env
    source_cert_push

    # Call the actual push_qnap function
    local output=$(push_qnap "$DOMAIN" "$MOCK_HOST" "$QNAP_USER" 2>&1)

    echo "$output" | grep -q "No existing certificate\|unable to read" || fail "Should detect no existing cert"
    echo "$output" | grep -q "Done" || fail "Should complete push"

    pass "QNAP fresh push works"
}

test_qnap_skip_unchanged() {
    info "TEST [QNAP]: Skip unchanged cert"

    setup_qnap_env
    source_cert_push

    # Push same cert again
    local output=$(push_qnap "$DOMAIN" "$MOCK_HOST" "$QNAP_USER" 2>&1)

    echo "$output" | grep -q "unchanged, skipping" || fail "Should skip unchanged cert"

    pass "QNAP skips unchanged certificate"
}

# -----------------------------------------------------------------------------
# Common Tests
# -----------------------------------------------------------------------------

test_missing_files() {
    info "TEST: Handle missing cert files"

    setup_mikrotik_env
    source_cert_push

    local output=$(push_mikrotik "nonexistent.example.com" "$MOCK_HOST" "$MIKROTIK_USER" 2>&1) || true

    echo "$output" | grep -q "Certificate files not found" || fail "Should report missing files"

    pass "Reports missing certificate files"
}

test_pkcs12_format() {
    info "TEST: PKCS12 format is MikroTik-compatible"

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
    pass "PKCS12 uses MikroTik-compatible legacy encryption"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

echo "=========================================="
echo "Integration Tests: cert-push.sh"
echo "=========================================="

setup

echo
echo "--- MikroTik Handler Tests ---"
test_mikrotik_fresh_push
test_mikrotik_skip_unchanged
test_mikrotik_push_changed

echo
echo "--- pfSense Handler Tests ---"
test_pfsense_fresh_push
test_pfsense_skip_unchanged

echo
echo "--- QNAP Handler Tests ---"
test_qnap_fresh_push
test_qnap_skip_unchanged

echo
echo "--- Common Tests ---"
test_missing_files
test_pkcs12_format

echo
echo "=========================================="
echo -e "\033[32mAll tests passed\033[0m"
echo "=========================================="
