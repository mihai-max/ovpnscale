FROM debian:bookworm-slim

# Base tooling: OpenVPN client, routing, NAT, TLS, sysctl, apt-key handling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        iptables \
        openvpn \
        procps \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Tailscale from the official Debian bookworm repo (provides tailscaled + tailscale).
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh healthcheck.sh webui.py /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/webui.py

# Persistent state: Tailscale node identity + uploaded .ovpn / settings.
VOLUME ["/var/lib/tailscale", "/data"]

# Setup web UI.
EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
