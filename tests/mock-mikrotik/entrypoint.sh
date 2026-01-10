#!/bin/bash
set -e

# If SSH public key provided via volume, install it
if [[ -f /state/authorized_keys ]]; then
    cp /state/authorized_keys /home/cert-push/.ssh/authorized_keys
    chmod 600 /home/cert-push/.ssh/authorized_keys
    chown cert-push:cert-push /home/cert-push/.ssh/authorized_keys
fi

# Ensure state directory is writable
chown -R cert-push:cert-push /state /files 2>/dev/null || true

# Clear previous state
rm -f /state/cert_*.fingerprint /state/cert_*.imported /state/command.log /state/unknown.log 2>/dev/null || true

echo "Mock MikroTik SSH server starting..."
echo "User: cert-push"
echo "State directory: /state"

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
