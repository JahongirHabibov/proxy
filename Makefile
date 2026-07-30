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

up: sync-config
	docker compose up -d

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
