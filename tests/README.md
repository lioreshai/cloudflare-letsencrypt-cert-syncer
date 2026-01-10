# Tests

Integration tests for the cert-push script.

## Quick Start (CI Tests)

```bash
./run_tests.sh
```

Uses a mock MikroTik SSH server. Fast, works everywhere, runs in GitHub Actions.

**Tests:**
- PKCS12 bundle creation with legacy encryption
- Certificate fingerprint extraction
- SSH/SCP connectivity
- Certificate import simulation
- Fingerprint comparison logic
- Certificate removal

## Full RouterOS Tests (Local Only)

```bash
./run_tests_routeros.sh
```

Uses actual MikroTik RouterOS running in QEMU. Requires:
- `/dev/kvm` (KVM virtualization support)
- `sshpass` (`apt install sshpass`)
- ~1 minute for RouterOS to boot

**Additional validation:**
- Real RouterOS certificate import behavior
- Actual `K` (private key) flag verification
- Real www-ssl service configuration

## Test Architecture

```
┌─────────────────────────────────────────────┐
│              run_tests.sh (CI)              │
│                                             │
│  ┌─────────────┐      ┌─────────────────┐   │
│  │ Test Script │─SSH─►│ Mock MikroTik   │   │
│  │             │      │ (Alpine + SSH)  │   │
│  └─────────────┘      └─────────────────┘   │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│       run_tests_routeros.sh (Local)         │
│                                             │
│  ┌─────────────┐      ┌─────────────────┐   │
│  │ Test Script │─SSH─►│ RouterOS in     │   │
│  │             │      │ QEMU/Docker     │   │
│  └─────────────┘      └─────────────────┘   │
└─────────────────────────────────────────────┘
```

## Adding Tests

Both test scripts follow the same pattern:

```bash
test_something() {
    log_info "TEST: Description"

    # Test logic here

    if [[ condition ]]; then
        log_pass "What succeeded"
    else
        log_fail "What failed"
        return 1
    fi
}
```

Add new tests to the main function and they'll be included in the run.
