#!/bin/bash
# Keepalived setup script for AdGuard Home VIP failover
# Usage: ./setup.sh <nuc8-1|nuc8-2>
#
# This script must be run with sudo on the target node.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${1:-}"

if [[ -z "$NODE" ]]; then
    echo "Usage: $0 <nuc8-1|nuc8-2>"
    exit 1
fi

if [[ "$NODE" != "nuc8-1" && "$NODE" != "nuc8-2" ]]; then
    echo "Error: Node must be 'nuc8-1' or 'nuc8-2'"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

echo "=== Installing keepalived on $NODE ==="

# Install keepalived (works on both Debian/Ubuntu and Fedora/RHEL)
if command -v apt &> /dev/null; then
    apt update && apt install -y keepalived
elif command -v dnf &> /dev/null; then
    dnf install -y keepalived
elif command -v yum &> /dev/null; then
    yum install -y keepalived
else
    echo "Error: Could not detect package manager"
    exit 1
fi

echo "=== Installing health check script ==="
cp "$SCRIPT_DIR/check_adguard.sh" /etc/keepalived/check_adguard.sh
chmod +x /etc/keepalived/check_adguard.sh

echo "=== Installing keepalived configuration for $NODE ==="
cp "$SCRIPT_DIR/keepalived-${NODE}.conf" /etc/keepalived/keepalived.conf

echo "=== Enabling and starting keepalived ==="
systemctl enable keepalived
systemctl start keepalived

echo "=== Verifying keepalived status ==="
systemctl status keepalived --no-pager

echo ""
echo "=== Setup complete for $NODE ==="
echo ""
echo "Check VIP ownership with:"
echo "  ip addr show eno1 | grep '192.168.0.25'"
echo ""
echo "Monitor keepalived with:"
echo "  sudo journalctl -u keepalived -f"
