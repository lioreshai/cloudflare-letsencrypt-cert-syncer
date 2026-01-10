#!/bin/bash
set -e

# If SSH public key provided via volume, install it
if [[ -f /state/authorized_keys ]]; then
    cp /state/authorized_keys /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# Clear previous state
rm -f /state/cert_*.crt /state/cert_*.key /state/command.log /state/unknown.log 2>/dev/null || true

echo "Mock pfSense SSH server starting..."
echo "User: root"
echo "State directory: /state"

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
