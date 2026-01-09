# Let's Encrypt SSL for MikroTik via Caddy + Cloudflare DNS

Automatically provision and renew valid Let's Encrypt SSL certificates for MikroTik RouterOS devices without opening any ports.

## The Problem

MikroTik RouterOS has built-in ACME support, but it requires:
- Port 80 open to the internet for HTTP-01 challenge
- The router to be publicly accessible

For home networks behind NAT or those who don't want to expose their router, this doesn't work.

## The Solution

Use **Caddy** as a certificate manager with **Cloudflare DNS-01 challenge**:

1. Caddy obtains certificates using DNS validation (no ports needed)
2. A script pushes renewed certificates to MikroTik via SSH
3. Daily cron checks for renewals and updates MikroTik automatically

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
         │ - Compare fingerprints
         │ - Create PKCS12 bundle
         │ - SCP to MikroTik
         │ - Import certificate
         ▼
┌─────────────────┐
│    MikroTik     │
│   www-ssl:443   │
└─────────────────┘
```

## Requirements

- **Caddy** with Cloudflare DNS plugin ([caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare))
  - Docker: `slothcroissant/caddy-cloudflaredns` or build your own
- **Cloudflare** managing your domain's DNS
- **Cloudflare API token** with Zone:DNS:Edit permission
- **MikroTik RouterOS 7.x** (tested on 7.20.6)
- **Linux server** to run Caddy and the push script
- **SSH key authentication** from Caddy server to MikroTik

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

# Add an entry for each MikroTik device
router.example.com {
    import cloudflare
    respond "Certificate endpoint for MikroTik" 200
}

switch.example.com {
    import cloudflare
    respond "Certificate endpoint for MikroTik" 200
}
```

Create `.env` with your Cloudflare API token:
```
CLOUDFLARE_API_TOKEN=your-token-here
```

### 2. Create MikroTik user with limited permissions

```
# Create restricted group
/user group add name=cert-push policy=ssh,ftp,read,write

# Create user (password required but SSH key will be used)
/user add name=cert-push group=cert-push password=random-string-not-used
```

### 3. Deploy SSH key to MikroTik

```bash
# Copy your public key to MikroTik
scp ~/.ssh/id_rsa.pub admin@192.168.1.1:server.pub

# On MikroTik, import for cert-push user
/user ssh-keys import user=cert-push public-key-file=server.pub
/file remove server.pub
```

### 4. Install the push script

Copy `mikrotik-cert-push.sh` to your Caddy server and configure:

```bash
# Edit the script to set your certificate path and devices
sudo cp mikrotik-cert-push.sh /opt/caddy/mikrotik-cert-push.sh
sudo chmod +x /opt/caddy/mikrotik-cert-push.sh
```

### 5. Run initial push

```bash
sudo /opt/caddy/mikrotik-cert-push.sh
```

### 6. Set up cron for automatic renewal

Create `/etc/cron.d/mikrotik-cert-push`:
```
# Check daily at 4 AM for renewed certificates
0 4 * * * root /opt/caddy/mikrotik-cert-push.sh >> /var/log/mikrotik-cert-push.log 2>&1
```

## Important Gotchas

### PKCS12 Format is Required

MikroTik doesn't properly associate private keys when importing separate PEM files. The private key gets imported as a "file" without cryptographic association.

**Solution:** The script creates a PKCS12 bundle with legacy encryption for MikroTik compatibility:

```bash
openssl pkcs12 -export \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -out cert.p12 -inkey cert.key -in cert.crt \
    -passout pass:yourpassword
```

### Certificate Must Have Private Key Flag

After importing, verify the certificate shows the `K` flag:

```
/certificate print
Flags: K - PRIVATE-KEY; L - CRL; T - TRUSTED
#     NAME           COMMON-NAME
0 KLT router.p12_0   router.example.com    ✓ Has K flag
```

If missing the `K` flag, the private key wasn't associated - re-import using PKCS12.

### DNS Cache Can Block ACME Verification

If your local DNS server caches records, it may interfere with Let's Encrypt's DNS verification.

**Solution:** Flush DNS cache before/during certificate generation:
```
/ip dns cache flush
```

### DNS Entry Order Matters

If you use wildcard DNS entries on MikroTik, specific entries must come BEFORE the wildcard:

```
# CORRECT - specific entry first
15   router.example.com    A   192.168.1.1
16   .*\.example\.com$     A   192.168.1.100

# WRONG - wildcard matches first
15   .*\.example\.com$     A   192.168.1.100
16   router.example.com    A   192.168.1.1
```

Use `place-before` when adding:
```
/ip dns static add name=router.example.com address=192.168.1.1 place-before=15
```

### Certificate Chain Must Be Complete

The PKCS12 import should show `certificates-imported: 2` - both the leaf certificate AND the intermediate (Let's Encrypt E8). If only 1 certificate was imported, browsers will show certificate errors even though `curl -k` works.

**Solution:** Remove the certificate on MikroTik and re-run the push script:
```
/certificate remove [find where common-name=router.example.com]
```

Then re-run the push script - it will detect the missing cert and push again.

Verify the chain:
```bash
openssl s_client -connect 192.168.1.1:443 -servername router.example.com </dev/null 2>&1 | head -10
# Should show depth=0 (leaf) and depth=1 (intermediate)
```

## Script Features

The `mikrotik-cert-push.sh` script:

- **Fingerprint comparison** - Only pushes when certificate actually changed
- **Per-device selective updates** - Each device is checked independently; only devices with new certs get updated
- **PKCS12 bundling** - Ensures private key association with full certificate chain
- **Legacy encryption** - Compatible with MikroTik's crypto support
- **Automatic cleanup** - Removes temporary files from MikroTik
- **Logging** - Detailed logs for troubleshooting
- **Multiple devices** - Configure as many MikroTik devices as needed

Example output showing selective updates:
```
Processing router.example.com -> 192.168.1.1
  Certificate unchanged, skipping push
Processing switch.example.com -> 192.168.1.2
  Certificate changed, pushing new cert...
  [push happens]
Processing ap.example.com -> 192.168.1.3
  Certificate unchanged, skipping push
```

## Extending to Multiple Devices

Edit the script's main section:

```bash
# Push to each device
push_cert "router.example.com" "192.168.1.1" "cert-push"
push_cert "switch.example.com" "192.168.1.2" "cert-push"
push_cert "ap.example.com" "192.168.1.3" "cert-push"
```

Each device needs:
1. Domain added to Caddyfile
2. `cert-push` user created
3. SSH key deployed

## Troubleshooting

### Certificate not serving (connection refused or invalid cert)

Check www-ssl service:
```
/ip service print where name=www-ssl
```

Verify certificate is assigned and service enabled:
```
/ip service set www-ssl certificate=router.example.com.p12_0 disabled=no
```

### SCP fails with permission denied

1. Verify SSH key is imported:
   ```
   /user ssh-keys print where user=cert-push
   ```

2. Verify group has `ftp` policy:
   ```
   /user group print where name=cert-push
   ```

### Import shows "decryption-failures: 1"

PKCS12 encryption incompatible. Regenerate with legacy flags (see script).

### Caddy fails to obtain certificate

1. Check API token permissions (Zone:DNS:Edit)
2. Flush local DNS cache
3. Check Caddy logs: `docker logs caddy 2>&1 | grep your-domain`
4. Increase `propagation_timeout` if DNS is slow

## Security Considerations

- **Limited permissions** - The `cert-push` user can only manage certificates and services, not full router config
- **SSH key only** - No password authentication for the automation user
- **PKCS12 password** - Used only during transport, not stored on MikroTik
- **Restrict www-ssl access** - Consider limiting to internal networks:
  ```
  /ip service set www-ssl address=192.168.0.0/16
  ```

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

Issues and pull requests welcome!
