# Tests

Integration tests for `mikrotik-cert-push.sh`.

**Tests the actual `push_cert()` function** from the main script, not a copy. Environment variables redirect SSH/SCP to a mock MikroTik container.

## Running Tests

```bash
./run_tests.sh
```

Requires Docker. Uses a mock MikroTik SSH server to test certificate operations.

## What's Tested

| Test | What it verifies |
|------|------------------|
| Fresh push | Pushes cert when none exists on device |
| Skip unchanged | Skips push when fingerprints match |
| Push changed | Detects and pushes when cert changes |
| Missing files | Reports error for missing cert files |
| PKCS12 format | Uses legacy encryption MikroTik requires |

## How It Works

```
┌──────────────┐         ┌─────────────────────┐
│  Test Script │──SSH───►│  Mock MikroTik      │
│              │         │  (Alpine + OpenSSH) │
│  push_cert() │◄────────│                     │
└──────────────┘         │  Simulates:         │
                         │  - /certificate     │
                         │  - fingerprint      │
                         │  - import/remove    │
                         └─────────────────────┘
```

The mock stores certificate fingerprints in `/state/` and responds to MikroTik-style commands.
