# Traefik Reverse Proxy

Docker-based reverse proxy using Traefik v3. Routes multiple domains to separate app containers on a single server. Handles SSL automatically via Let's Encrypt.

## Features

- Automatic HTTPS with Let's Encrypt (free, auto-renews)
- HTTP → HTTPS redirect (301 permanent)
- www → non-www redirect (301 permanent)
- Traefik dashboard with BasicAuth
- Docker socket proxy (security hardening — Traefik never touches the socket directly)
- Global security headers (HSTS, XSS protection, etc.)
- All sensitive values controlled via `.env`

## Prerequisites

- Docker + Docker Compose v2
- Domain DNS: A record for every domain (and `www.*`) pointing to your server IP
- `apache2-utils` for password generation: `sudo apt install apache2-utils`

## Setup

### 1. Clone and configure

```bash
git clone <repo-url>
cd proxy
make setup       # creates .env from .env.example and traefik/acme.json with chmod 600
```

### 2. Edit `.env`

```dotenv
ACME_EMAIL=your@email.com
TRAEFIK_DOMAIN=proxy.yourdomain.com
DASHBOARD_USERS=admin:$$apr1$$...
NETWORK_NAME=proxy-network
```

Generate the `DASHBOARD_USERS` value:

```bash
make gen-password
# Enter username and password → copy output into .env
```

### 3. Start the proxy

```bash
make up
```

Traefik is now running. Dashboard available at `https://<TRAEFIK_DOMAIN>` once DNS resolves.

## Adding a website

Each website is a separate project. Copy the labels from `docs/app-example/docker-compose.yml` into your app's `docker-compose.yml`.

**Required replacements:**

| Placeholder | Replace with |
|-------------|-------------|
| `example.com` | your domain (e.g. `mysite.de`) |
| `myapp` | unique short name (e.g. `mysite`) |
| `3000` | internal container port |

**DNS requirement:** Both `example.com` and `www.example.com` must have an A record pointing to the server IP before starting the app — Let's Encrypt needs to reach your domain to issue the certificate.

Then start your app:

```bash
docker compose up -d
```

Traefik auto-discovers the container and issues SSL certificates immediately.

## Project structure

```
proxy/
├── traefik/
│   ├── traefik.yml          # Static config (entrypoints, providers, API)
│   ├── config/
│   │   └── dynamic.yml      # Global middlewares (www-redirect, security-headers)
│   └── acme.json            # Let's Encrypt certificates — never commit this
├── docker-compose.yml
├── .env                     # Secrets — never commit this
├── .env.example             # Template for .env
├── .gitignore
├── Makefile
└── docs/
    └── app-example/
        └── docker-compose.yml  # Template for app projects
```

## Makefile commands

| Command | Action |
|---------|--------|
| `make setup` | Create `.env` from template + initialize `acme.json` |
| `make up` | Start proxy in background |
| `make down` | Stop proxy |
| `make logs` | Stream Traefik logs |
| `make restart` | Restart Traefik container |
| `make gen-password` | Generate BasicAuth hash for `DASHBOARD_USERS` |

## Security notes

- `traefik/acme.json` contains Let's Encrypt private keys — keep it on the server only
- `.env` contains secrets — never commit it
- Traefik connects to Docker via socket-proxy, not directly via `/var/run/docker.sock`
- Dashboard is protected by BasicAuth over HTTPS
