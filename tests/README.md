# Tests

Integration tests for the MikroTik handler in `cert-push.sh`.

Tests the **actual `push_mikrotik()` function** against a mock MikroTik SSH server.

## Running Tests

```bash
./run_tests.sh
```

Requires Docker.

## What's Tested

| Test | What it verifies |
|------|------------------|
| Fresh push | Pushes cert when none exists on device |
| Skip unchanged | Skips push when fingerprints match |
| Push changed | Detects and pushes when cert changes |
| Missing files | Reports error for missing cert files |
| PKCS12 format | Uses legacy encryption (SHA1/3DES) MikroTik requires |

## How It Works

```
┌──────────────────┐         ┌─────────────────────┐
│   Test Script    │──SSH───►│   Mock MikroTik     │
│                  │         │   (Alpine + SSH)    │
│  Sources actual  │◄────────│                     │
│  cert-push.sh    │         │  Simulates:         │
│                  │         │  - /certificate     │
│  Overrides env   │         │  - fingerprint      │
│  variables       │         │  - import/remove    │
└──────────────────┘         └─────────────────────┘
```

The mock stores certificate fingerprints in `/state/` and responds to MikroTik-style commands.

## Why Only MikroTik?

The PKCS12 format test is genuinely valuable - MikroTik requires legacy encryption (PBE-SHA1-3DES) that modern OpenSSL doesn't use by default. This test catches regressions.

pfSense and QNAP handlers are tested manually since their mocks would need to simulate PHP execution and sudo behavior respectively, adding complexity without proportional value.
