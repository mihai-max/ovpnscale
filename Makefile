COMPOSE ?= docker compose
SERVICE ?= ovpn-exit

.PHONY: build up down restart logs shell status ip ps

build:
	$(COMPOSE) build

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f $(SERVICE)

ps:
	$(COMPOSE) ps

shell:
	$(COMPOSE) exec $(SERVICE) bash

# Run the tunnel healthcheck inside the container.
status:
	$(COMPOSE) exec $(SERVICE) /usr/local/bin/healthcheck.sh && echo "VPN: up" || echo "VPN: down"

# Show the public IP as seen through the VPN tunnel.
ip:
	$(COMPOSE) exec $(SERVICE) sh -c 'IF=$$(ls /sys/class/net | grep -E "^tun[0-9]+$$" | head -n1); curl -fsS --interface $$IF https://api.ipify.org; echo'
