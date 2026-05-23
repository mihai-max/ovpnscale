#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# OpenVPN egress + Tailscale exit node (Headscale)
#
# OpenVPN (tunX) provides internet egress; Tailscale (tailscale0) joins Headscale
# and advertises this node as an exit node. Only packets that ingress on
# tailscale0 (i.e. forwarded exit-node traffic) are policy-routed out the VPN.
# The container's own traffic (Tailscale control/DERP, the OpenVPN control
# channel, the healthcheck underlay) keeps using the real default interface.
#
# Configuration comes from the first-run web UI (see webui.py), which persists an
# uploaded .ovpn + settings to $DATA_DIR. Environment variables are used as
# fallback defaults. Country/region selection = which provider .ovpn you upload.
# ----------------------------------------------------------------------------

TS_STATE_DIR=/var/lib/tailscale
TS_SOCK=/var/run/tailscale/tailscaled.sock
TS_IF=tailscale0
RT_TABLE=51820
RULE_PRIO=100
DATA_DIR=/data
WEBUI_PORT="${WEBUI_PORT:-8080}"

# Initial values from the environment act as defaults; the web UI (config.env in
# $DATA_DIR) overrides them once setup is submitted.
ENV_HEADSCALE_URL="${HEADSCALE_URL:-}"
ENV_TS_AUTHKEY="${TS_AUTHKEY:-}"
ENV_TS_HOSTNAME="${TS_HOSTNAME:-ovpn-exit}"
ENV_TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
ENV_OVPN_AUTH_USER="${OVPN_AUTH_USER:-}"
ENV_OVPN_AUTH_PASS="${OVPN_AUTH_PASS:-}"
ENV_OVPN_AUTH_FILE="${OVPN_AUTH_FILE:-}"
ENV_OVPN_CONFIG="${OVPN_CONFIG:-}"

log() { echo "[entrypoint] $*"; }

mkdir -p "$TS_STATE_DIR" /var/run/tailscale "$DATA_DIR"

WEBUI_PID=""
OVPN_PID=""
TAILSCALED_PID=""
OVPN_IF=""
OVPN_V6=0

cleanup() {
    log "shutting down..."
    if [ -n "$TAILSCALED_PID" ] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
        tailscale --socket="$TS_SOCK" down 2>/dev/null || true
        kill "$TAILSCALED_PID" 2>/dev/null || true
    fi
    [ -n "$OVPN_PID" ] && kill "$OVPN_PID" 2>/dev/null || true
    [ -n "$WEBUI_PID" ] && kill "$WEBUI_PID" 2>/dev/null || true
    ip rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
    ip -6 rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# ----- 0. setup web UI + load configuration ---------------------------------
# Resolve effective config from environment defaults overridden by the persisted
# config.env (written by the web UI). Parsed line-by-line WITHOUT `source`, so a
# password containing shell metacharacters can never be executed.
load_config() {
    HEADSCALE_URL="$ENV_HEADSCALE_URL"
    TS_AUTHKEY="$ENV_TS_AUTHKEY"
    TS_HOSTNAME="$ENV_TS_HOSTNAME"
    TS_EXTRA_ARGS="$ENV_TS_EXTRA_ARGS"
    OVPN_AUTH_USER="$ENV_OVPN_AUTH_USER"
    OVPN_AUTH_PASS="$ENV_OVPN_AUTH_PASS"
    OVPN_AUTH_FILE="$ENV_OVPN_AUTH_FILE"
    OVPN_CONFIG="$ENV_OVPN_CONFIG"
    if [ -f "$DATA_DIR/config.env" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                HEADSCALE_URL)  HEADSCALE_URL="$v" ;;
                TS_AUTHKEY)     [ -n "$v" ] && TS_AUTHKEY="$v" ;;
                TS_HOSTNAME)    [ -n "$v" ] && TS_HOSTNAME="$v" ;;
                TS_EXTRA_ARGS)  TS_EXTRA_ARGS="$v" ;;
                OVPN_AUTH_USER) OVPN_AUTH_USER="$v" ;;
                OVPN_AUTH_PASS) OVPN_AUTH_PASS="$v" ;;
                OVPN_AUTH_FILE) OVPN_AUTH_FILE="$v" ;;
            esac
        done < "$DATA_DIR/config.env"
    fi
    [ -f "$DATA_DIR/client.ovpn" ] && OVPN_CONFIG="$DATA_DIR/client.ovpn"
}

config_ready() {
    [ -n "$HEADSCALE_URL" ] && [ -n "$OVPN_CONFIG" ] && [ -f "$OVPN_CONFIG" ]
}

log "starting setup web UI on :$WEBUI_PORT ..."
DATA_DIR="$DATA_DIR" WEBUI_PORT="$WEBUI_PORT" python3 /usr/local/bin/webui.py &
WEBUI_PID=$!

load_config
if ! config_ready; then
    log "Not configured yet — open the setup web UI (http://<host>:$WEBUI_PORT)"
    log "to upload your .ovpn and enter your Headscale URL + credentials."
    until config_ready; do
        sleep 2
        load_config
    done
fi
log "configuration ready (profile: $OVPN_CONFIG); starting tunnel..."

# --route-nopull: ignore the server's pushed routes/redirect-gateway/DNS so the
# VPN does NOT become the container's global default route. We set up our own
# policy routing instead (only exit-node traffic egresses via the VPN).
OVPN_ARGS=(--config "$OVPN_CONFIG" --route-nopull)
if [ -n "${OVPN_AUTH_USER:-}" ] && [ -n "${OVPN_AUTH_PASS:-}" ]; then
    printf '%s\n%s\n' "$OVPN_AUTH_USER" "$OVPN_AUTH_PASS" > /tmp/ovpn-auth.txt
    chmod 600 /tmp/ovpn-auth.txt
    OVPN_ARGS+=(--auth-user-pass /tmp/ovpn-auth.txt)
elif [ -n "${OVPN_AUTH_FILE:-}" ]; then
    OVPN_ARGS+=(--auth-user-pass "$OVPN_AUTH_FILE")
fi

# ----- 2. enable IP forwarding ----------------------------------------------
# /proc/sys is read-only in a non-privileged container, so `sysctl -w` usually
# fails; in that case the value must be supplied at run time with
# `docker run --sysctl ...` (already set in docker-compose.yml).
enable_forwarding() {
    # $1 = sysctl key, $2 = /proc path
    sysctl -w "$1=1" >/dev/null 2>&1 && return 0
    [ "$(cat "$2" 2>/dev/null || echo 0)" = "1" ]
}
if enable_forwarding net.ipv4.ip_forward /proc/sys/net/ipv4/ip_forward; then
    log "IPv4 forwarding enabled"
else
    log "FATAL: net.ipv4.ip_forward is off and cannot be set from inside the container."
    log "       Re-run with:  --sysctl net.ipv4.ip_forward=1   (already set in docker-compose.yml)"
    exit 1
fi
HAVE_V6=0
if enable_forwarding net.ipv6.conf.all.forwarding /proc/sys/net/ipv6/conf/all/forwarding; then
    HAVE_V6=1
    log "IPv6 forwarding enabled"
else
    log "IPv6 forwarding unavailable; continuing IPv4-only"
fi

# ----- 3. start OpenVPN -----------------------------------------------------
log "starting OpenVPN ($OVPN_CONFIG)..."
openvpn "${OVPN_ARGS[@]}" &
OVPN_PID=$!

# Detect the tun interface OpenVPN created. tailscaled hasn't started yet, so the
# only tunN device present is OpenVPN's (tailscale's is named "tailscale0").
for _ in $(seq 1 120); do
    kill -0 "$OVPN_PID" 2>/dev/null || { log "FATAL: OpenVPN exited during startup (see log above)"; exit 1; }
    OVPN_IF=$(ls /sys/class/net 2>/dev/null | grep -E '^tun[0-9]+$' | head -n1 || true)
    if [ -n "$OVPN_IF" ] && ip -4 addr show "$OVPN_IF" 2>/dev/null | grep -q 'inet '; then
        break
    fi
    OVPN_IF=""
    sleep 0.5
done
[ -n "$OVPN_IF" ] || { log "FATAL: OpenVPN tunnel interface did not come up in time"; exit 1; }
log "OpenVPN tunnel up on $OVPN_IF"

# ----- 4. policy routing: dedicated table whose default route is the VPN -----
ip route replace default dev "$OVPN_IF" table "$RT_TABLE"
if [ "$HAVE_V6" = 1 ] && ip -6 addr show "$OVPN_IF" 2>/dev/null | grep -q 'inet6 .*scope global'; then
    if ip -6 route replace default dev "$OVPN_IF" table "$RT_TABLE" 2>/dev/null; then
        OVPN_V6=1
    fi
fi

# ----- 5. NAT forwarded traffic onto the VPN + clamp MSS to the tunnel MTU ---
iptables  -t nat    -C POSTROUTING -o "$OVPN_IF" -j MASQUERADE 2>/dev/null \
    || iptables  -t nat    -A POSTROUTING -o "$OVPN_IF" -j MASQUERADE
iptables  -t mangle -C FORWARD -o "$OVPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables  -t mangle -A FORWARD -o "$OVPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
if [ "$OVPN_V6" = 1 ]; then
    ip6tables -t nat    -C POSTROUTING -o "$OVPN_IF" -j MASQUERADE 2>/dev/null \
        || ip6tables -t nat    -A POSTROUTING -o "$OVPN_IF" -j MASQUERADE 2>/dev/null || true
    ip6tables -t mangle -C FORWARD -o "$OVPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || ip6tables -t mangle -A FORWARD -o "$OVPN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi

# ----- 6. start tailscaled --------------------------------------------------
log "starting tailscaled..."
tailscaled \
    --state="${TS_STATE_DIR}/tailscaled.state" \
    --socket="$TS_SOCK" \
    --tun="$TS_IF" \
    --port=41641 &
TAILSCALED_PID=$!

# wait for the control socket and the TUN interface (created at tailscaled startup)
for _ in $(seq 1 60); do
    [ -S "$TS_SOCK" ] && ip link show "$TS_IF" >/dev/null 2>&1 && break
    sleep 0.5
done

# ----- 7. send forwarded (iif tailscale0) traffic into the VPN table ---------
ip rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
ip rule add iif "$TS_IF" lookup "$RT_TABLE" priority "$RULE_PRIO"
if [ "$OVPN_V6" = 1 ]; then
    ip -6 rule del iif "$TS_IF" lookup "$RT_TABLE" 2>/dev/null || true
    ip -6 rule add iif "$TS_IF" lookup "$RT_TABLE" priority "$RULE_PRIO" 2>/dev/null || true
fi

# ----- 8. join Headscale and advertise as an exit node ----------------------
# Auth (node key) is saved to ${TS_STATE_DIR}/tailscaled.state on the ts-data
# volume, so login is only needed once; restarts reconnect automatically.
TS_UP_ARGS=(
    --login-server="$HEADSCALE_URL"
    --hostname="$TS_HOSTNAME"
    --advertise-exit-node
    --accept-dns=false
)
if [ -n "$TS_AUTHKEY" ]; then
    log "connecting to Headscale at $HEADSCALE_URL using a preauth key..."
    TS_UP_ARGS+=(--authkey="$TS_AUTHKEY")
else
    log "no TS_AUTHKEY set -> interactive login."
    log "=================================================================="
    log " An authentication URL will be printed below. Open it, then on your"
    log " Headscale server register the node, e.g.:"
    log "   headscale nodes register --user <user> --key <nodekey-from-URL>"
    log " The login is saved to the ts-data volume, so this is a one-time step."
    log "=================================================================="
fi
# shellcheck disable=SC2086
tailscale --socket="$TS_SOCK" up "${TS_UP_ARGS[@]}" $TS_EXTRA_ARGS

log "ready: exit-node traffic now egresses through OpenVPN ($OVPN_IF)."
log "NOTE: approve this node's exit route on Headscale (0.0.0.0/0, ::/0) before clients can use it."

# ----- 9. stay alive; exit (and let Docker restart) if either process dies ---
wait -n "$OVPN_PID" "$TAILSCALED_PID" || true
log "a managed process exited; shutting down"
cleanup
