#!/bin/bash
#
# Full integration tests using actual MikroTik RouterOS
# Requires /dev/kvm for reasonable performance - run locally, not in CI
#
# Uses evilfreelancer/docker-routeros which runs RouterOS in QEMU
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test configuration
TEST_DOMAIN="test.example.com"
TEST_P12_PASS="test-password-123"
ROUTEROS_HOST="127.0.0.1"
ROUTEROS_PORT="2222"
ROUTEROS_USER="admin"
CONTAINER_NAME="test-routeros"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((TESTS_PASSED++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; ((TESTS_FAILED++)); }

cleanup() {
    log_info "Cleaning up..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/tmp" 2>/dev/null || true
}

trap cleanup EXIT

check_kvm() {
    if [[ ! -e /dev/kvm ]]; then
        echo -e "${RED}ERROR: /dev/kvm not available${NC}"
        echo "This test requires KVM for RouterOS emulation."
        echo "Run on a machine with KVM support, or use ./run_tests.sh for mock-based tests."
        exit 1
    fi
}

start_routeros() {
    log_info "Starting RouterOS container (this may take 30-60 seconds)..."

    docker run -d \
        --name "$CONTAINER_NAME" \
        --cap-add NET_ADMIN \
        --device /dev/net/tun \
        --device /dev/kvm \
        -p "$ROUTEROS_PORT:22" \
        evilfreelancer/docker-routeros:latest

    # Wait for RouterOS to boot and SSH to be available
    log_info "Waiting for RouterOS to boot..."
    local max_attempts=60
    for i in $(seq 1 $max_attempts); do
        if sshpass -p "" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
            -o ConnectTimeout=3 -p "$ROUTEROS_PORT" "$ROUTEROS_USER@$ROUTEROS_HOST" \
            "/system identity print" 2>/dev/null | grep -q "name:"; then
            log_info "RouterOS is ready (took ~${i}s)"
            return 0
        fi
        sleep 1
        printf "."
    done
    echo

    log_fail "RouterOS failed to start within ${max_attempts}s"
    docker logs "$CONTAINER_NAME"
    return 1
}

setup_routeros_user() {
    log_info "Creating cert-push user on RouterOS..."

    # Create group with limited permissions
    sshpass -p "" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "$ROUTEROS_USER@$ROUTEROS_HOST" \
        "/user group add name=cert-push policy=ssh,ftp,read,write" 2>/dev/null || true

    # Create user
    sshpass -p "" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "$ROUTEROS_USER@$ROUTEROS_HOST" \
        "/user add name=cert-push group=cert-push password=testpass123" 2>/dev/null || true

    log_pass "cert-push user created"
}

generate_test_certificate() {
    local domain="$1"
    local cert_dir="$SCRIPT_DIR/tmp/certs/$domain"

    log_info "Generating test certificate for $domain..."
    mkdir -p "$cert_dir"

    # Generate private key
    openssl genrsa -out "$cert_dir/$domain.key" 2048 2>/dev/null

    # Generate certificate with chain
    openssl req -new -x509 -key "$cert_dir/$domain.key" \
        -out "$cert_dir/$domain.crt" -days 30 \
        -subj "/CN=$domain" 2>/dev/null

    # Create intermediate cert
    openssl req -new -x509 -key "$cert_dir/$domain.key" \
        -out "$cert_dir/chain.crt" -days 30 \
        -subj "/CN=Test Intermediate CA" 2>/dev/null

    # Combine into full chain
    cat "$cert_dir/$domain.crt" "$cert_dir/chain.crt" > "$cert_dir/$domain.crt.full"
    mv "$cert_dir/$domain.crt.full" "$cert_dir/$domain.crt"
}

# =============================================================================
# TEST: Full certificate push to real RouterOS
# =============================================================================
test_full_cert_push() {
    log_info "TEST: Full certificate push to RouterOS"

    local cert_dir="$SCRIPT_DIR/tmp/certs/$TEST_DOMAIN"
    local p12_file="$SCRIPT_DIR/tmp/$TEST_DOMAIN.p12"

    # Create PKCS12 with legacy encryption
    openssl pkcs12 -export \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -out "$p12_file" \
        -inkey "$cert_dir/$TEST_DOMAIN.key" \
        -in "$cert_dir/$TEST_DOMAIN.crt" \
        -passout "pass:$TEST_P12_PASS" 2>/dev/null

    # Upload via SCP
    log_info "  Uploading certificate..."
    sshpass -p "testpass123" scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -P "$ROUTEROS_PORT" "$p12_file" "cert-push@$ROUTEROS_HOST:$TEST_DOMAIN.p12"

    # Import certificate
    log_info "  Importing certificate..."
    local import_result
    import_result=$(sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        "/certificate import file-name=$TEST_DOMAIN.p12 passphrase=$TEST_P12_PASS" 2>&1)

    echo "$import_result"

    if echo "$import_result" | grep -q "private-keys-imported: 1"; then
        log_pass "Certificate imported with private key"
    else
        log_fail "Private key not imported"
        return 1
    fi

    # Verify certificate has K flag
    log_info "  Verifying certificate flags..."
    local cert_info
    cert_info=$(sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        "/certificate print where name~\"$TEST_DOMAIN\"" 2>&1)

    echo "$cert_info"

    if echo "$cert_info" | grep -q "K"; then
        log_pass "Certificate has private key flag (K)"
    else
        log_fail "Certificate missing private key flag"
        return 1
    fi

    # Configure www-ssl
    log_info "  Configuring www-ssl service..."
    local cert_name="${TEST_DOMAIN}.p12_0"
    sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        "/ip service set www-ssl certificate=\"$cert_name\" disabled=no" 2>&1

    log_pass "www-ssl configured with certificate"

    # Cleanup
    sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        "/file remove \"$TEST_DOMAIN.p12\"" 2>/dev/null || true

    rm -f "$p12_file"
}

# =============================================================================
# TEST: Fingerprint retrieval from real RouterOS
# =============================================================================
test_fingerprint_retrieval() {
    log_info "TEST: Fingerprint retrieval from RouterOS"

    local fingerprint
    fingerprint=$(sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        ":put [/certificate get [find where common-name=$TEST_DOMAIN] fingerprint]" 2>&1)

    # Normalize
    fingerprint=$(echo "$fingerprint" | tr -d ':' | tr '[:upper:]' '[:lower:]' | tr -d '\r\n' | xargs)

    if [[ -n "$fingerprint" && ${#fingerprint} -eq 64 ]]; then
        log_pass "Fingerprint retrieved: ${fingerprint:0:16}..."
    else
        log_fail "Failed to retrieve fingerprint (got: '$fingerprint', length: ${#fingerprint})"
        return 1
    fi
}

# =============================================================================
# TEST: Certificate removal
# =============================================================================
test_cert_removal() {
    log_info "TEST: Certificate removal from RouterOS"

    sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        "/certificate remove [find where common-name=$TEST_DOMAIN]" 2>&1

    # Verify removal
    local remaining
    remaining=$(sshpass -p "testpass123" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -p "$ROUTEROS_PORT" "cert-push@$ROUTEROS_HOST" \
        "/certificate print count-only where common-name=$TEST_DOMAIN" 2>&1)

    if [[ "$remaining" == "0" ]]; then
        log_pass "Certificate removed successfully"
    else
        log_fail "Certificate not removed (count: $remaining)"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo "========================================"
    echo "RouterOS Integration Tests"
    echo "(Full integration with real RouterOS)"
    echo "========================================"
    echo

    # Check prerequisites
    check_kvm

    if ! command -v sshpass &>/dev/null; then
        echo -e "${RED}ERROR: sshpass is required${NC}"
        echo "Install with: apt install sshpass"
        exit 1
    fi

    mkdir -p "$SCRIPT_DIR/tmp"

    start_routeros || exit 1
    setup_routeros_user
    generate_test_certificate "$TEST_DOMAIN"

    echo
    echo "Running tests against real RouterOS..."
    echo "----------------------------------------"

    test_full_cert_push
    test_fingerprint_retrieval
    test_cert_removal

    echo
    echo "========================================"
    echo -e "Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "========================================"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
