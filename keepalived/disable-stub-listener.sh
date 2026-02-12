#!/bin/bash
# Disable systemd-resolved stub listener to free port 53 for AdGuard
# This script must be run with sudo on each node.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

RESOLVED_CONF="/etc/systemd/resolved.conf"
RESOLVED_CONF_D="/etc/systemd/resolved.conf.d"

echo "=== Disabling systemd-resolved stub listener ==="

# Create drop-in directory if it doesn't exist
mkdir -p "$RESOLVED_CONF_D"

# Create drop-in config to disable stub listener
cat > "$RESOLVED_CONF_D/no-stub-listener.conf" << 'EOF'
# Disable stub listener so AdGuard can bind to port 53
# Created by keepalived setup for AdGuard Home
[Resolve]
DNSStubListener=no
EOF

echo "Created $RESOLVED_CONF_D/no-stub-listener.conf"

# Restart systemd-resolved
echo "Restarting systemd-resolved..."
systemctl restart systemd-resolved

# Verify stub listener is disabled
sleep 1
if ss -ulnp | grep -q "127.0.0.53:53"; then
    echo "WARNING: Stub listener still active on 127.0.0.53:53"
    exit 1
else
    echo "Stub listener disabled successfully"
fi

# Update /etc/resolv.conf symlink if it points to stub-resolv.conf
if [[ -L /etc/resolv.conf ]]; then
    LINK_TARGET=$(readlink /etc/resolv.conf)
    if [[ "$LINK_TARGET" == *"stub-resolv.conf"* ]]; then
        echo "Updating /etc/resolv.conf symlink..."
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        echo "Now using upstream DNS servers directly"
    fi
fi

echo ""
echo "=== Done ==="
echo "Port 53 on 127.0.0.1 is now available for AdGuard"
