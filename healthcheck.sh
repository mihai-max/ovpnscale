#!/usr/bin/env bash
# Verify the OpenVPN tunnel works by fetching the public IP bound to the VPN's
# tun interface. tailscale's TUN is named "tailscale0", so grepping for tunN
# selects only the OpenVPN interface. Binding to it (SO_BINDTODEVICE) forces the
# request through the VPN even though the container's normal traffic bypasses it.
set -euo pipefail

# During first-run setup (no profile uploaded via the web UI yet) report healthy
# so the container isn't flagged while it waits for configuration.
[ -f /data/client.ovpn ] || { echo "awaiting setup via web UI"; exit 0; }

IF=$(ls /sys/class/net 2>/dev/null | grep -E '^tun[0-9]+$' | head -n1 || true)
[ -n "$IF" ] || { echo "no OpenVPN tun interface present"; exit 1; }

curl -fsS --interface "$IF" --max-time 5 https://api.ipify.org >/dev/null
