#!/bin/bash
#
# Integration tests for mikrotik-cert-push.sh
# Tests the actual push_cert function against a mock MikroTik SSH endpoint
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test configuration
TEST_DOMAIN="test.example.com"
TEST_P12_PASS="test-password-123"
MOCK_HOST="127.0.0.1"
MOCK_PORT="2222"
MOCK_USER="cert-push"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((++TESTS_PASSED)) || true; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; ((++TESTS_FAILED)) || true; }

cleanup() {
    log_info "Cleaning up..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/tmp" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/mock-mikrotik/state/authorized_keys" 2>/dev/null || true
}

trap cleanup EXIT

setup_test_environment() {
    log_info "Setting up test environment..."

    mkdir -p "$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"
    mkdir -p "$SCRIPT_DIR/mock-mikrotik/state"

    # Generate SSH key pair for tests
    if [[ ! -f "$SCRIPT_DIR/tmp/test_key" ]]; then
        ssh-keygen -t ed25519 -f "$SCRIPT_DIR/tmp/test_key" -N "" -q
    fi
    cp "$SCRIPT_DIR/tmp/test_key.pub" "$SCRIPT_DIR/mock-mikrotik/state/authorized_keys"

    # Start mock MikroTik
    log_info "Starting mock MikroTik container..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.test.yml build --quiet
    docker compose -f docker-compose.test.yml up -d

    # Wait for SSH
    log_info "Waiting for SSH to be ready..."
    for i in {1..30}; do
        if ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=2 \
            -i "$SCRIPT_DIR/tmp/test_key" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" \
            "echo ready" 2>/dev/null | grep -q "ready"; then
            log_info "Mock MikroTik is ready"
            return 0
        fi
        sleep 1
    done
    log_fail "Mock MikroTik failed to start"
    docker compose -f docker-compose.test.yml logs
    return 1
}

generate_test_certificate() {
    local domain="$1"
    local cert_dir="$SCRIPT_DIR/tmp/certs/$domain"

    log_info "Generating test certificate for $domain..."
    mkdir -p "$cert_dir"

    openssl genrsa -out "$cert_dir/$domain.key" 2048 2>/dev/null
    openssl req -new -x509 -key "$cert_dir/$domain.key" \
        -out "$cert_dir/$domain.crt" -days 30 \
        -subj "/CN=$domain" 2>/dev/null

    # Add intermediate cert to chain
    openssl req -new -x509 -key "$cert_dir/$domain.key" \
        -out "$cert_dir/chain.crt" -days 30 \
        -subj "/CN=Test Intermediate CA" 2>/dev/null
    cat "$cert_dir/$domain.crt" "$cert_dir/chain.crt" > "$cert_dir/$domain.crt.tmp"
    mv "$cert_dir/$domain.crt.tmp" "$cert_dir/$domain.crt"
}

# Source the actual script to get push_cert function
# We override config variables for testing
source_push_cert() {
    # Override configuration for testing
    export CERT_BASE="$SCRIPT_DIR/tmp/certs"
    export LOG_FILE="$SCRIPT_DIR/tmp/test.log"
    export P12_PASS="$TEST_P12_PASS"
    export SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10 -i $SCRIPT_DIR/tmp/test_key -p $MOCK_PORT"

    # Source just the functions from the script (not the main execution)
    # Extract and eval just the function definitions
    eval "$(sed -n '/^log()/,/^}$/p' "$PROJECT_DIR/mikrotik-cert-push.sh")"
    eval "$(sed -n '/^push_cert()/,/^}$/p' "$PROJECT_DIR/mikrotik-cert-push.sh")"
}

# =============================================================================
# TEST: push_cert with no existing certificate (fresh push)
# =============================================================================
test_fresh_push() {
    log_info "TEST: push_cert() - fresh push (no existing cert on device)"

    source_push_cert

    # Clear any existing state in mock
    ssh $SSH_OPTS "${MOCK_USER}@${MOCK_HOST}" \
        "/certificate remove [find where common-name=$TEST_DOMAIN]" 2>/dev/null || true

    # Run the actual push_cert function
    local output
    output=$(push_cert "$TEST_DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1) || true

    # Verify it detected no existing cert
    if echo "$output" | grep -q "No existing certificate found"; then
        log_pass "Correctly detected no existing certificate"
    else
        log_fail "Did not detect missing certificate"
        echo "$output"
        return 1
    fi

    # Verify it pushed the cert
    if echo "$output" | grep -q "Done! www-ssl enabled"; then
        log_pass "Successfully pushed certificate"
    else
        log_fail "Failed to push certificate"
        echo "$output"
        return 1
    fi

    # Verify certificate is now on "device"
    local fingerprint
    fingerprint=$(ssh $SSH_OPTS "${MOCK_USER}@${MOCK_HOST}" \
        ":put [/certificate get [find where common-name=$TEST_DOMAIN] fingerprint]" 2>/dev/null)

    if [[ -n "$fingerprint" ]]; then
        log_pass "Certificate now exists on device"
    else
        log_fail "Certificate not found on device after push"
        return 1
    fi
}

# =============================================================================
# TEST: push_cert skips when fingerprint matches (idempotent)
# =============================================================================
test_skip_unchanged() {
    log_info "TEST: push_cert() - skip when certificate unchanged"

    source_push_cert

    # Run push_cert again with same cert (should skip)
    local output
    output=$(push_cert "$TEST_DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1) || true

    if echo "$output" | grep -q "Certificate unchanged, skipping push"; then
        log_pass "Correctly skipped unchanged certificate"
    else
        log_fail "Did not skip unchanged certificate"
        echo "$output"
        return 1
    fi
}

# =============================================================================
# TEST: push_cert detects changed certificate
# =============================================================================
test_detect_changed() {
    log_info "TEST: push_cert() - detect and push changed certificate"

    source_push_cert

    # Generate a NEW certificate (different fingerprint)
    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"
    openssl genrsa -out "$cert_dir/$TEST_DOMAIN.key" 2048 2>/dev/null
    openssl req -new -x509 -key "$cert_dir/$TEST_DOMAIN.key" \
        -out "$cert_dir/$TEST_DOMAIN.crt" -days 30 \
        -subj "/CN=$TEST_DOMAIN" 2>/dev/null

    # Run push_cert with new cert
    local output
    output=$(push_cert "$TEST_DOMAIN" "$MOCK_HOST" "$MOCK_USER" 2>&1) || true

    if echo "$output" | grep -q "Certificate changed, pushing new cert"; then
        log_pass "Correctly detected certificate change"
    else
        log_fail "Did not detect certificate change"
        echo "$output"
        return 1
    fi

    if echo "$output" | grep -q "Done! www-ssl enabled"; then
        log_pass "Successfully pushed new certificate"
    else
        log_fail "Failed to push new certificate"
        return 1
    fi
}

# =============================================================================
# TEST: push_cert handles missing certificate files
# =============================================================================
test_missing_cert_files() {
    log_info "TEST: push_cert() - handle missing certificate files"

    source_push_cert

    # Try to push a domain that doesn't have cert files
    local output
    output=$(push_cert "nonexistent.example.com" "$MOCK_HOST" "$MOCK_USER" 2>&1) || true

    if echo "$output" | grep -q "ERROR: Certificate files not found"; then
        log_pass "Correctly reported missing certificate files"
    else
        log_fail "Did not report missing certificate files"
        echo "$output"
        return 1
    fi
}

# =============================================================================
# TEST: PKCS12 bundle has correct format for MikroTik
# =============================================================================
test_pkcs12_format() {
    log_info "TEST: PKCS12 bundle format (legacy encryption for MikroTik)"

    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"
    local p12_file="$SCRIPT_DIR/tmp/test_format.p12"

    # Create PKCS12 using the exact same command as the script
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -out "$p12_file" \
        -inkey "$cert_dir/$TEST_DOMAIN.key" \
        -in "$cert_dir/$TEST_DOMAIN.crt" \
        -passout "pass:$TEST_P12_PASS" 2>/dev/null

    # Verify it can be read (proves format is valid)
    local p12_info
    p12_info=$(openssl pkcs12 -in "$p12_file" -info -passin "pass:$TEST_P12_PASS" -noout 2>&1) || true

    # Check for legacy encryption markers
    if echo "$p12_info" | grep -qi "pbeWithSHA1And3-KeyTripleDES-CBC\|sha1"; then
        log_pass "PKCS12 uses legacy encryption (MikroTik compatible)"
    else
        log_fail "PKCS12 may not use legacy encryption"
        echo "$p12_info"
    fi

    # Verify cert and key are both present
    local contents
    contents=$(openssl pkcs12 -in "$p12_file" -passin "pass:$TEST_P12_PASS" \
        -passout "pass:temp" 2>/dev/null) || true

    local has_cert has_key
    has_cert=$(echo "$contents" | grep -c "BEGIN CERTIFICATE") || has_cert=0
    has_key=$(echo "$contents" | grep -c "BEGIN.*PRIVATE KEY") || has_key=0

    if [[ "$has_cert" -ge 1 && "$has_key" -ge 1 ]]; then
        log_pass "PKCS12 contains certificate and private key"
    else
        log_fail "PKCS12 missing certificate or key (cert=$has_cert, key=$has_key)"
    fi

    rm -f "$p12_file"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo "========================================"
    echo "Integration Tests: mikrotik-cert-push.sh"
    echo "========================================"
    echo

    setup_test_environment || exit 1
    generate_test_certificate "$TEST_DOMAIN"

    echo
    echo "Running tests against actual push_cert function..."
    echo "----------------------------------------"

    test_fresh_push
    test_skip_unchanged
    test_detect_changed
    test_missing_cert_files
    test_pkcs12_format

    echo
    echo "========================================"
    echo -e "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "========================================"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
