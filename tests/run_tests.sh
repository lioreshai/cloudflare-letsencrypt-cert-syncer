#!/bin/bash
#
# Integration tests for cloudflare-letsencrypt-cert-syncer
# Tests the cert-push script against a mock MikroTik SSH endpoint
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
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((TESTS_FAILED++))
}

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

    # Create temp directory for test certificates
    mkdir -p "$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"

    # Generate SSH key pair for tests
    if [[ ! -f "$SCRIPT_DIR/tmp/test_key" ]]; then
        ssh-keygen -t ed25519 -f "$SCRIPT_DIR/tmp/test_key" -N "" -q
    fi

    # Copy public key to mock-mikrotik state directory
    mkdir -p "$SCRIPT_DIR/mock-mikrotik/state"
    cp "$SCRIPT_DIR/tmp/test_key.pub" "$SCRIPT_DIR/mock-mikrotik/state/authorized_keys"

    # Start mock MikroTik
    log_info "Starting mock MikroTik container..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.test.yml build --quiet
    docker compose -f docker-compose.test.yml up -d

    # Wait for SSH to be ready
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

    # Generate private key
    openssl genrsa -out "$cert_dir/$domain.key" 2048 2>/dev/null

    # Generate self-signed certificate
    openssl req -new -x509 -key "$cert_dir/$domain.key" \
        -out "$cert_dir/$domain.crt" -days 30 \
        -subj "/CN=$domain" 2>/dev/null

    # Also create a "chain" cert (self-signed intermediate for testing)
    openssl req -new -x509 -key "$cert_dir/$domain.key" \
        -out "$cert_dir/chain.crt" -days 30 \
        -subj "/CN=Test Intermediate CA" 2>/dev/null

    # Combine into full chain (cert + intermediate)
    cat "$cert_dir/$domain.crt" "$cert_dir/chain.crt" > "$cert_dir/$domain.crt.full"
    mv "$cert_dir/$domain.crt.full" "$cert_dir/$domain.crt"

    log_info "Certificate generated: $cert_dir/$domain.crt"
}

# =============================================================================
# TEST: PKCS12 bundle creation
# =============================================================================
test_pkcs12_creation() {
    log_info "TEST: PKCS12 bundle creation with legacy encryption"

    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"
    local p12_file="$SCRIPT_DIR/tmp/test.p12"

    # Create PKCS12 with legacy encryption (same as cert-push script)
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -out "$p12_file" \
        -inkey "$cert_dir/$TEST_DOMAIN.key" \
        -in "$cert_dir/$TEST_DOMAIN.crt" \
        -passout "pass:$TEST_P12_PASS" 2>/dev/null

    if [[ ! -f "$p12_file" ]]; then
        log_fail "PKCS12 file was not created"
        return 1
    fi

    # Verify PKCS12 can be read
    local cert_count
    cert_count=$(openssl pkcs12 -in "$p12_file" -nokeys -passin "pass:$TEST_P12_PASS" 2>/dev/null | \
        grep -c "BEGIN CERTIFICATE" || echo "0")

    if [[ "$cert_count" -ge 1 ]]; then
        log_pass "PKCS12 bundle created successfully (contains $cert_count certificates)"
    else
        log_fail "PKCS12 bundle is empty or invalid"
        return 1
    fi

    # Verify private key is included
    local key_present
    key_present=$(openssl pkcs12 -in "$p12_file" -nocerts -passin "pass:$TEST_P12_PASS" \
        -passout "pass:temp" 2>/dev/null | grep -c "BEGIN" || echo "0")

    if [[ "$key_present" -ge 1 ]]; then
        log_pass "PKCS12 bundle contains private key"
    else
        log_fail "PKCS12 bundle missing private key"
        return 1
    fi

    rm -f "$p12_file"
}

# =============================================================================
# TEST: Fingerprint extraction
# =============================================================================
test_fingerprint_extraction() {
    log_info "TEST: Certificate fingerprint extraction"

    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"

    # Extract fingerprint (same method as cert-push script)
    local fingerprint
    fingerprint=$(openssl x509 -in "$cert_dir/$TEST_DOMAIN.crt" -noout -fingerprint -sha256 2>/dev/null | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    if [[ -n "$fingerprint" && ${#fingerprint} -eq 64 ]]; then
        log_pass "Fingerprint extracted: ${fingerprint:0:16}... (64 chars)"
    else
        log_fail "Failed to extract valid fingerprint (got: $fingerprint)"
        return 1
    fi
}

# =============================================================================
# TEST: SSH connection to mock MikroTik
# =============================================================================
test_ssh_connection() {
    log_info "TEST: SSH connection to mock MikroTik"

    local result
    result=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" \
        "echo connected" 2>&1)

    if echo "$result" | grep -q "connected"; then
        log_pass "SSH connection successful"
    else
        log_fail "SSH connection failed: $result"
        return 1
    fi
}

# =============================================================================
# TEST: SCP file upload
# =============================================================================
test_scp_upload() {
    log_info "TEST: SCP file upload to mock MikroTik"

    local test_file="$SCRIPT_DIR/tmp/scp_test.txt"
    echo "test content" > "$test_file"

    scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -P "$MOCK_PORT" \
        "$test_file" "$MOCK_USER@$MOCK_HOST:scp_test.txt" 2>&1

    if [[ $? -eq 0 ]]; then
        log_pass "SCP upload successful"
    else
        log_fail "SCP upload failed"
        return 1
    fi

    rm -f "$test_file"
}

# =============================================================================
# TEST: Certificate import (mock MikroTik command)
# =============================================================================
test_certificate_import() {
    log_info "TEST: Certificate import via mock MikroTik"

    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"
    local p12_file="$SCRIPT_DIR/tmp/$TEST_DOMAIN.p12"

    # Create PKCS12
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -out "$p12_file" \
        -inkey "$cert_dir/$TEST_DOMAIN.key" \
        -in "$cert_dir/$TEST_DOMAIN.crt" \
        -passout "pass:$TEST_P12_PASS" 2>/dev/null

    # Upload PKCS12
    scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -P "$MOCK_PORT" \
        "$p12_file" "$MOCK_USER@$MOCK_HOST:$TEST_DOMAIN.p12" 2>&1

    # Import certificate
    local import_result
    import_result=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" \
        "/certificate import file-name=$TEST_DOMAIN.p12 passphrase=$TEST_P12_PASS" 2>&1)

    if echo "$import_result" | grep -q "private-keys-imported: 1"; then
        log_pass "Certificate import successful (private key imported)"
    else
        log_fail "Certificate import failed: $import_result"
        return 1
    fi

    # Verify certificate count
    if echo "$import_result" | grep -q "certificates-imported: 2"; then
        log_pass "Full certificate chain imported (2 certificates)"
    else
        log_info "Note: Expected 2 certificates in chain"
    fi

    rm -f "$p12_file"
}

# =============================================================================
# TEST: Fingerprint comparison (unchanged cert should skip push)
# =============================================================================
test_fingerprint_comparison() {
    log_info "TEST: Fingerprint comparison (skip unchanged cert)"

    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"

    # Get expected fingerprint
    local expected_fingerprint
    expected_fingerprint=$(openssl x509 -in "$cert_dir/$TEST_DOMAIN.crt" -noout -fingerprint -sha256 2>/dev/null | \
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    # Query fingerprint from mock MikroTik (should return what we imported)
    local stored_fingerprint
    stored_fingerprint=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" \
        ":put [/certificate get [find where common-name=$TEST_DOMAIN] fingerprint]" 2>&1 | \
        tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')

    if [[ "$expected_fingerprint" == "$stored_fingerprint" ]]; then
        log_pass "Fingerprint match - cert-push would skip (expected behavior)"
    else
        log_fail "Fingerprint mismatch: expected=$expected_fingerprint, got=$stored_fingerprint"
        return 1
    fi
}

# =============================================================================
# TEST: Certificate removal
# =============================================================================
test_certificate_removal() {
    log_info "TEST: Certificate removal from mock MikroTik"

    # Remove certificate
    ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" \
        "/certificate remove [find where common-name=$TEST_DOMAIN]" 2>&1

    # Verify it's gone
    local fingerprint
    fingerprint=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=5 \
        -i "$SCRIPT_DIR/tmp/test_key" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" \
        ":put [/certificate get [find where common-name=$TEST_DOMAIN] fingerprint]" 2>&1)

    if [[ -z "$fingerprint" || "$fingerprint" == "" ]]; then
        log_pass "Certificate removed successfully"
    else
        log_fail "Certificate still present after removal: $fingerprint"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo "========================================"
    echo "Integration Tests: cert-push"
    echo "========================================"
    echo

    setup_test_environment || exit 1
    generate_test_certificate "$TEST_DOMAIN"

    echo
    echo "Running tests..."
    echo "----------------------------------------"

    # Run all tests
    test_pkcs12_creation
    test_fingerprint_extraction
    test_ssh_connection
    test_scp_upload
    test_certificate_import
    test_fingerprint_comparison
    test_certificate_removal

    echo
    echo "========================================"
    echo "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "========================================"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
