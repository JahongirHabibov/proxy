SHELL := /bin/bash

.PHONY: setup up down logs restart gen-password

setup:
	@test -f .env || (cp .env.example .env && echo "Created .env from .env.example — fill in your values before running 'make up'")
	@mkdir -p traefik && touch traefik/acme.json && chmod 600 traefik/acme.json
	@echo "traefik/acme.json: chmod 600 OK"

up:
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
