# Cloudflare Let's Encrypt Cert Syncer

[![Integration Tests](https://github.com/lioreshai/cloudflare-letsencrypt-cert-syncer/actions/workflows/test.yml/badge.svg)](https://github.com/lioreshai/cloudflare-letsencrypt-cert-syncer/actions/workflows/test.yml)

Automatically provision and renew Let's Encrypt SSL certificates for network devices without opening any ports to the internet.

Supports:
- **MikroTik RouterOS** - Routers and switches
- **pfSense** - Firewalls
- **QNAP** - NAS devices

Uses **Caddy** with **Cloudflare DNS-01 challenge** for secure, firewall-friendly certificate management.

## The Problem

Many network devices have built-in ACME support, but require:
- Port 80 open to the internet for HTTP-01 challenge
- The device to be publicly accessible

For home networks behind NAT or those who don't want to expose management interfaces, this doesn't work.

## The Solution

Use **Caddy** as a certificate manager with **Cloudflare DNS-01 challenge**:

1. Caddy obtains certificates using DNS validation (no ports needed)
2. Scripts push renewed certificates to each device via SSH
3. Daily cron checks for renewals and updates devices automatically

```
┌─────────────────┐     DNS-01      ┌─────────────────┐
│   Let's Encrypt │◄───Challenge────│    Cloudflare   │
└────────┬────────┘                 └─────────────────┘
         │                                   ▲
         │ Certificate                       │ TXT Record
         ▼                                   │
┌─────────────────┐                 ┌────────┴────────┐
│  Caddy Server   │────Cloudflare───│   Caddy Config  │
│  Cert Storage   │    API Token    │   (Caddyfile)   │
└────────┬────────┘                 └─────────────────┘
         │
         │ Daily cron (only if cert renewed)
         ▼
┌────────────────────────────────────────────────────┐
│              cert-push.sh                          │
│  - Compare fingerprints                            │
│  - Push only changed certs                         │
│  - Device-specific handlers                        │
└────────┬───────────────┬───────────────┬──────────┘
         │               │               │
         ▼               ▼               ▼
    ┌─────────┐    ┌──────────┐    ┌──────────┐
    │MikroTik │    │ pfSense  │    │   QNAP   │
    │ PKCS12  │    │ PHP API  │    │   PEM    │
    └─────────┘    └──────────┘    └──────────┘
```

## Project Structure

```
├── cert-push.sh           # Main dispatcher script
├── lib/
│   ├── mikrotik.sh        # MikroTik handler (PKCS12)
│   ├── pfsense.sh         # pfSense handler (PHP API)
│   └── qnap.sh            # QNAP handler (PEM bundle)
├── mikrotik-cert-push.sh  # Standalone MikroTik-only script
└── tests/                 # Integration tests with Docker mocks
```

## Requirements

- **Caddy** with Cloudflare DNS plugin ([caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare))
  - Docker: `slothcroissant/caddy-cloudflaredns` or build your own
- **Cloudflare** managing your domain's DNS
- **Cloudflare API token** with Zone:DNS:Edit permission
- **Linux server** to run Caddy and the push script
- **SSH key authentication** to target devices

### Device-specific Requirements

| Device | SSH User | Additional |
|--------|----------|------------|
| MikroTik RouterOS 7.x | Limited `cert-push` user | ssh,ftp,read,write permissions |
| pfSense | root | Full access required |
| QNAP | Any sudo user | SUDO_PASS environment variable |

## Quick Start

### 1. Set up Caddy with Cloudflare DNS

Create a `Caddyfile`:

```caddy
{
    # Global options
}

(cloudflare) {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        resolvers 1.1.1.1 8.8.8.8
        propagation_timeout 5m
    }
}

# Add an entry for each device
router.example.com {
    import cloudflare
    respond "Certificate endpoint" 200
}

firewall.example.com {
    import cloudflare
    respond "Certificate endpoint" 200
}

nas.example.com {
    import cloudflare
    respond "Certificate endpoint" 200
}
```

Create `.env` with your Cloudflare API token:
```
CLOUDFLARE_API_TOKEN=your-token-here
```

### 2. Set up SSH key authentication

Deploy your SSH key to each device:

**MikroTik:**
```bash
scp ~/.ssh/id_rsa.pub admin@192.168.1.1:server.pub
# On MikroTik:
/user ssh-keys import user=cert-push public-key-file=server.pub
/file remove server.pub
```

**pfSense:**
```bash
ssh-copy-id root@192.168.1.254
```

**QNAP:**
```bash
ssh-copy-id admin@192.168.1.100
```

### 3. Create MikroTik user (MikroTik only)

```
/user group add name=cert-push policy=ssh,ftp,read,write
/user add name=cert-push group=cert-push password=random-string-not-used
```

### 4. Install and configure

```bash
git clone https://github.com/lioreshai/cloudflare-letsencrypt-cert-syncer.git
cd cloudflare-letsencrypt-cert-syncer

# Edit cert-push.sh to configure your devices and CERT_BASE path
vim cert-push.sh
```

Configure devices in the main section:
```bash
# MikroTik devices
push_cert mikrotik "router.example.com" "192.168.1.1" "cert-push"
push_cert mikrotik "switch.example.com" "192.168.1.2" "cert-push"

# pfSense firewall
push_cert pfsense "firewall.example.com" "192.168.1.254" "root"

# QNAP NAS (set SUDO_PASS environment variable)
push_cert qnap "nas.example.com" "192.168.1.100" "admin"
```

### 5. Run initial push

```bash
# For QNAP targets, set sudo password
export SUDO_PASS="your-sudo-password"

./cert-push.sh
```

### 6. Set up cron for automatic renewal

Create `/etc/cron.d/cert-push`:
```
# Check daily at 4 AM for renewed certificates
0 4 * * * root SUDO_PASS="your-sudo-password" /opt/cert-push/cert-push.sh >> /var/log/cert-push.log 2>&1
```

## Device-Specific Details

### MikroTik

Uses PKCS12 format with legacy encryption (PBE-SHA1-3DES) for compatibility.

**Gotchas:**
- Certificate must show `K` flag (private key associated)
- PKCS12 import should show `private-keys-imported: 1`
- Use `certificates-imported: 2` to verify chain is complete

### pfSense

Uses PHP API via SSH to import certificates and configure webConfigurator.

**Gotchas:**
- Requires root SSH access
- sshguard may block IPs with failed attempts (`pfctl -t sshguard -T show`)
- Restarts webConfigurator after import

### QNAP

Uses combined PEM format (key + cert) and sudo for elevated privileges.

**Gotchas:**
- Requires `SUDO_PASS` environment variable
- Restarts thttpd web server after install
- Certificate stored at `/etc/stunnel/stunnel.pem`

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CERT_BASE` | Path to Caddy certificate storage | See script |
| `LOG_FILE` | Log file location | `/var/log/cert-push.log` |
| `P12_PASS` | PKCS12 password (MikroTik) | `change-this-password` |
| `SUDO_PASS` | Sudo password (QNAP) | Required for QNAP |
| `SSH_OPTS` | SSH options | `-o StrictHostKeyChecking=no ...` |
| `SCP_OPTS` | SCP options | Same as SSH_OPTS |

## Script Features

- **Fingerprint comparison** - Only pushes when certificate actually changed
- **Per-device selective updates** - Each device checked independently
- **Device-specific handlers** - Proper format for each device type
- **Automatic cleanup** - Removes temporary files
- **Detailed logging** - For troubleshooting

Example output:
```
=== Certificate Push Started ===
Processing router.example.com -> 192.168.1.1 [mikrotik]
  Certificate unchanged, skipping push
Processing firewall.example.com -> 192.168.1.254 [pfsense]
  Certificate changed, pushing new cert...
  Done! pfSense webConfigurator updated with new certificate
Processing nas.example.com -> 192.168.1.100 [qnap]
  Certificate unchanged, skipping push
=== Certificate Push Completed ===
```

## Troubleshooting

### Certificate not serving

**MikroTik:**
```
/ip service print where name=www-ssl
/ip service set www-ssl certificate=router.example.com.p12_0 disabled=no
```

**pfSense:** Check System > Certificate Manager and System > Advanced > Admin Access

**QNAP:** Verify `/etc/stunnel/stunnel.pem` exists and thttpd is running

### SCP/SSH fails

1. Verify SSH key authentication works manually
2. Check user permissions
3. For pfSense, check sshguard: `pfctl -t sshguard -T show`

### PKCS12 import shows decryption failures

PKCS12 encryption incompatible. The script uses legacy flags automatically.

### Caddy fails to obtain certificate

1. Check API token permissions (Zone:DNS:Edit)
2. Flush local DNS cache
3. Check Caddy logs
4. Increase `propagation_timeout` if DNS is slow

## Testing

Integration tests verify all handlers against Docker mock servers.

```bash
cd tests
./run_tests.sh
```

See [tests/README.md](tests/README.md) for details.

## Standalone MikroTik Script

If you only need MikroTik support, use the standalone `mikrotik-cert-push.sh` which has no dependencies on the `lib/` handlers.

## Security Considerations

- **Limited permissions** - MikroTik `cert-push` user can only manage certificates
- **SSH key only** - No password authentication for automation
- **PKCS12 password** - Used only during transport, not stored
- **Restrict management access** - Consider limiting to internal networks

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

Issues and pull requests welcome!
