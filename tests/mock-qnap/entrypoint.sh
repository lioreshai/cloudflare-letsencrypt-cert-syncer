#!/bin/bash
set -e

# If SSH public key provided via volume, install it
if [[ -f /state/authorized_keys ]]; then
    cp /state/authorized_keys /home/qnap/.ssh/authorized_keys
    chmod 600 /home/qnap/.ssh/authorized_keys
    chown qnap:qnap /home/qnap/.ssh/authorized_keys
fi

# Ensure directories are writable
chown -R qnap:qnap /state /etc/stunnel /home/qnap 2>/dev/null || true
chmod 777 /state /etc/stunnel 2>/dev/null || true

# Clear previous state
rm -f /state/stunnel.pem /state/command.log /state/unknown.log 2>/dev/null || true

echo "Mock QNAP SSH server starting..."
echo "User: qnap"
echo "State directory: /state"

# Start SSH daemon in foreground
exec /usr/sbin/sshd -D -e
