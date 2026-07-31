SHELL := /bin/bash

# Shared with the customer website stack: the website api writes one Traefik
# router file per customer site into this volume, Traefik reads it as its file
# provider directory. The uid is the api container's non-root user.
DYNAMIC_VOLUME   := traefik-dynamic
WEBSITE_API_UID  := 10001

.PHONY: setup up down logs restart gen-password sync-config

setup:
	@test -f .env || (cp .env.example .env && echo "Created .env from .env.example — fill in your values before running 'make up'")
	@mkdir -p traefik && touch traefik/acme.json && chmod 600 traefik/acme.json
	@echo "traefik/acme.json: chmod 600 OK"
	@docker volume inspect $(DYNAMIC_VOLUME) >/dev/null 2>&1 \
		|| docker volume create $(DYNAMIC_VOLUME) >/dev/null
	@# A fresh named volume starts out root-owned, and whichever container mounts
	@# it first would decide the ownership. Traefik mounts it read-only, so the
	@# writer's uid is set here explicitly rather than left to start-up order.
	@docker run --rm -v $(DYNAMIC_VOLUME):/target alpine:3.20 \
		chown $(WEBSITE_API_UID):$(WEBSITE_API_UID) /target >/dev/null
	@echo "$(DYNAMIC_VOLUME): present, writable for the website api (uid $(WEBSITE_API_UID))"
	@$(MAKE) --no-print-directory sync-config

# Copies this project's dynamic.yml into the shared volume. The live container
# gets the file bind-mounted on top (so edits still hot-reload); this copy is the
# fallback for a start-up without that bind, where Traefik would otherwise read
# an empty mountpoint file and lose every middleware.
sync-config:
	@docker run --rm \
		-v $(DYNAMIC_VOLUME):/target \
		-v "$(CURDIR)/traefik/config/dynamic.yml":/source:ro \
		alpine:3.20 cp /source /target/dynamic.yml
	@echo "dynamic.yml synced into $(DYNAMIC_VOLUME) (fallback copy)"

# Traefik publishes 80/443/8443 itself now; in the old layout the tailscale
# sidecar published them and Traefik borrowed its namespace. On a host still
# running the old container, `up` therefore fails with "port is already
# allocated" — and the obvious next move, `docker compose up -d
# --remove-orphans`, silently deletes containers this file no longer defines.
# That is how the tailnet node was lost on 2026-07-31, taking admin.legisell.de
# with it (`legisell-ts-only`, see legisell-deployment) and leaving no error that
# pointed at the cause.
#
# So the conflict is named here, with the one safe move, before compose turns it
# into a puzzle.
PORT_HOLDER = $(shell docker ps --filter publish=80 --format '{{.Names}}' 2>/dev/null | grep -v '^traefik$$' | head -1)

up: sync-config
	@if [ -n "$(PORT_HOLDER)" ]; then \
		echo "REFUSING TO START: container '$(PORT_HOLDER)' already publishes port 80."; \
		echo ""; \
		echo "Traefik publishes 80/443/8443 itself, so the two cannot both run."; \
		echo "A container from the old layout is still holding them."; \
		echo ""; \
		echo "Do NOT use 'docker compose up -d --remove-orphans' to clear this."; \
		echo "It removes whatever this compose file does not define, which is how"; \
		echo "the tailnet node was lost once already."; \
		echo ""; \
		echo "Named removal only, so nothing else goes with it:"; \
		echo ""; \
		echo "    docker rm -f $(PORT_HOLDER) && make up"; \
		exit 1; \
	fi
	docker compose up -d
	@$(MAKE) --no-print-directory check-tailnet

# The tailnet is a dependency of this proxy that lives outside it:
# admin.legisell.de is gated on 100.64.0.0/10 (`legisell-ts-only`, defined in
# legisell-deployment; api.legisell.de is public and unaffected). Its A record
# points AT a tailnet address, so the node being down breaks the name itself.
# When the host node is logged out, the admin UI answers 403 to
# everyone — which is indistinguishable from a correctly working allowlist, so the
# outage is invisible from here. Hence a warning on every `up`, not a silent
# assumption. A warning, not a failure: the proxy serves every public site fine
# without a tailnet, and refusing to start would turn a partial outage into a
# total one.
.PHONY: check-tailnet
check-tailnet:
	@if ! command -v tailscale >/dev/null 2>&1; then \
		echo "NOTE: no tailscale binary on this host — admin.legisell.de is"; \
		echo "      tailnet-gated and will be unreachable."; \
	elif ! tailscale status >/dev/null 2>&1; then \
		echo "WARNING: the tailnet node is down or logged out."; \
		echo "         admin.legisell.de is unreachable while this is true: its A"; \
		echo "         record points at a tailnet address, and its allowlist only"; \
		echo "         admits 100.64.0.0/10. The 403 looks exactly like a working"; \
		echo "         allowlist. Bring it back with:"; \
		echo ""; \
		echo "             tailscale up --accept-dns=false"; \
		echo ""; \
		echo "         (--accept-dns=false keeps tailscaled off the host resolver"; \
		echo "          that every container inherits.)"; \
	else \
		echo "tailnet: up as $$(tailscale ip -4 2>/dev/null | head -1) — check that this"; \
		echo "         matches TAILSCALE_LOCAL_IP in legisell-deployment/.env"; \
	fi

down:
	docker compose down

logs:
	docker compose logs -f traefik

restart:
	docker compose restart traefik

gen-password:
	@which htpasswd > /dev/null 2>&1 || { echo "ERROR: htpasswd not found. Install with: sudo apt install apache2-utils"; exit 1; }
	@read -p "Username: " user; \
	read -s -p "Password: " pass; echo; \
	hash=$$(htpasswd -nb "$$user" "$$pass"); \
	escaped=$$(echo "$$hash" | sed 's/\$$/\$$\$$/g'); \
	echo ""; \
	echo "Paste this into DASHBOARD_USERS in .env:"; \
	echo "$$escaped"
