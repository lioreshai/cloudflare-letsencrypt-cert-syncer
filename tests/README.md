# Tests

Integration tests for `cert-push.sh` and all device handlers.

**Tests the actual handler functions** from the main script, not copies. Environment variables redirect SSH/SCP to mock containers.

## Running Tests

```bash
./run_tests.sh
```

Requires Docker. Uses mock SSH servers to simulate each device type.

## What's Tested

### MikroTik Handler

| Test | What it verifies |
|------|------------------|
| Fresh push | Pushes cert when none exists on device |
| Skip unchanged | Skips push when fingerprints match |
| Push changed | Detects and pushes when cert changes |
| PKCS12 format | Uses legacy encryption MikroTik requires |

### pfSense Handler

| Test | What it verifies |
|------|------------------|
| Fresh push | Pushes cert via PHP API when none exists |
| Skip unchanged | Skips push when fingerprints match |

### QNAP Handler

| Test | What it verifies |
|------|------------------|
| Fresh push | Pushes cert via sudo when none exists |
| Skip unchanged | Skips push when fingerprints match |

### Common

| Test | What it verifies |
|------|------------------|
| Missing files | Reports error for missing cert files |

## How It Works

```
┌──────────────────┐      ┌─────────────────────┐
│   Test Script    │      │   Mock MikroTik     │
│                  │─SSH──│   (Alpine + SSH)    │
│  Source actual   │      │   Port 2222         │
│  cert-push.sh    │      └─────────────────────┘
│                  │      ┌─────────────────────┐
│  Override env    │─SSH──│   Mock pfSense      │
│  variables       │      │   (Alpine + SSH)    │
│                  │      │   Port 2223         │
│  Call real       │      └─────────────────────┘
│  push_* funcs    │      ┌─────────────────────┐
│                  │─SSH──│   Mock QNAP         │
│                  │      │   (Alpine + SSH)    │
│                  │      │   Port 2224         │
└──────────────────┘      └─────────────────────┘
```

Each mock:
- Accepts SSH connections with test key
- Responds to device-specific commands
- Stores certificate state in `/state/` volume
- Returns fingerprints for comparison tests

## Mock Details

### mock-mikrotik
Simulates RouterOS commands:
- `/certificate get` - returns stored fingerprint
- `/certificate import` - stores cert, returns import stats
- `/certificate remove` - clears stored cert
- `/ip service set` - acknowledges command

### mock-pfsense
Simulates pfSense PHP API:
- `php -r '..config_get_path..'` - returns stored cert
- `php /tmp/import_cert.php` - imports cert, stores state
- `/etc/rc.restart_webgui` - acknowledges command

### mock-qnap
Simulates QNAP with sudo:
- `sudo cat /etc/stunnel/stunnel.pem` - returns stored cert
- `sudo cp *.pem /etc/stunnel/stunnel.pem` - stores cert
- `sudo /etc/init.d/thttpd.sh` - acknowledges restart

## Adding New Tests

1. Add test function in `run_tests.sh`:
```bash
test_new_feature() {
    info "TEST: Description"
    setup_<device>_env
    source_cert_push

    local output=$(push_<device> "$DOMAIN" "$MOCK_HOST" "$USER" 2>&1)

    echo "$output" | grep -q "expected output" || fail "Should do something"
    pass "New feature works"
}
```

2. Call the test in main section:
```bash
test_new_feature
```

3. If mock needs new commands, update the mock shell script.
