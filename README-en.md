# Traefik Reverse Proxy

Docker-based reverse proxy using Traefik v3. Routes multiple domains to separate app containers on a single server. Handles SSL automatically via Let's Encrypt.

> **Before changing anything in this repository, read
> [`docs/shared-surface.md`](docs/shared-surface.md).**
>
> One Traefik fronts every web service on this host, and the entrypoints,
> middlewares, TLS options and certificate resolver defined here are shared by all
> of them. A change that looks local to one service silently changes every other.
> That document lists what is shared, who consumes it, how to verify a change
> against each class of consumer, and the host-level dependencies (tailscaled and
> its SNAT setting, DNS records pointing into the tailnet) that no repository
> captures.

## Features

- Automatic HTTPS with Let's Encrypt (free, auto-renews) — single cert lifecycle for **all** entrypoints
- HTTP → HTTPS redirect (301 permanent)
- www → non-www redirect (301 permanent)
- Three entrypoints: `web` (:80), `websecure` (:443), `poslicense` (:8443)
- Public vs **Tailnet-only** services via a reusable IP-allowlist middleware (`ts-only`)
- Traefik dashboard — Tailnet-only + BasicAuth (defense in depth)
- Docker socket proxy (security hardening — Traefik never touches the socket directly)
- Global security headers (HSTS, XSS protection, etc.)
- Encoded-character path handling **disabled** (blocks split-view / allowlist bypass)
- Scoped backend TLS transport (no global `insecureSkipVerify`)
- TLS 1.2+ floor with a modern cipher suite
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

Traefik is now running. Dashboard available at `https://<TRAEFIK_DOMAIN>` once DNS resolves (Tailnet-only — see below).

## Architecture

Traefik runs in the network namespace of a Tailscale sidecar (`network_mode: service:tailscale`), so the sidecar publishes the host ports and Traefik shares them:

```
Public internet
      │
   :80  ─→ web        ─→ 301 redirect to :443  +  ACME HTTP-01 challenge
   :443 ─→ websecure  ─→ admin apps            (Tailnet-only via ts-only)
   :8443─→ poslicense ─→ public API            (public, backend enforces auth)
      │
   ┌──┴─────────────── Traefik v3 ───────────────┐
   │  ACME (Let's Encrypt) — one cert lifecycle   │
   │  reads containers via socket-proxy (RO)      │
   └──┬───────────────────────────────────────────┘
      │ https, verified per-service (legisell-internal transport)
      ▼
   app containers on proxy-network
```

Entrypoints are defined in `traefik/traefik.yml`; shared middlewares, the `ts-only`
allowlist, the scoped `legisell-internal` backend transport, and the default TLS
options live in `traefik/config/dynamic.yml` (hot-reloaded, `watch: true`).

## Public vs Tailnet-only services

Services fall into two access classes. The distinction is enforced by the
`ts-only` middleware (`ipAllowList` for the Tailscale CGNAT range
`100.64.0.0/10`) plus DNS.

| Service | Example host | Access | How |
|---------|-------------|--------|-----|
| Public API | `api.example.com:8443` | Anyone | No allowlist; the backend enforces its own auth / path allowlist |
| Admin app | `admin.example.com` | Tailnet only | `ts-only` middleware + Tailnet-routed DNS |
| Dashboard | `proxy.example.com` | Tailnet only | `ts-only` middleware + BasicAuth |

### The split-DNS pattern (Tailnet-only + valid Let's Encrypt cert)

A Tailnet-only host still needs a **public** Let's Encrypt certificate. Reconcile
the two with split DNS — two answers for the same name:

1. **Public authoritative record → public server IP** (e.g. `203.0.113.10`).
   Let's Encrypt validates HTTP-01 against this over `:80`, so the cert issues
   and auto-renews. Public clients that hit this IP are rejected by `ts-only`
   (their source IP is not in `100.64.0.0/10`).

2. **Tailnet override → server Tailscale IP** (e.g. `100.64.0.10`).
   Tailnet devices resolve the name to the server's Tailscale IP and route over
   the VPN. Traefik then sees a source IP inside `100.64.0.0/10`, so `ts-only`
   lets the request through.

Result: the service is invisible/blocked from the public internet, reachable
only from the Tailnet, and still serves a browser-trusted Let's Encrypt cert.

**Add a new Tailnet-only host:**

- Public DNS: `A  proxy.example.com → 203.0.113.10` (public IP, for Let's Encrypt).
- Tailnet override: `proxy.example.com → 100.64.0.10` (server Tailscale IP) via
  your Tailscale split-DNS / MagicDNS config — the same place the admin host is
  overridden.
- Attach `ts-only@file` to the router's middleware chain.

**Quick local test before configuring DNS** — pin the name to the server's
Tailscale IP on a Tailnet device:

```bash
echo "100.64.0.10 proxy.example.com" | sudo tee -a /etc/hosts
# browse https://proxy.example.com → trusted cert + reachable → then remove:
sudo sed -i '/proxy.example.com/d' /etc/hosts
```

A `403 Forbidden` on a Tailnet-only host means you reached it from a
non-Tailnet source IP — the DNS override is missing, not a proxy misconfig.

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

## Customer websites (one stack, many hosts)

The KASSIO customer-website stack (`retail-website-template`) does not use
container labels: one deployment serves every customer, so the hosts are not
known at start-up. Instead it writes **one router file per customer site** into a
Docker volume shared with this project:

```
website api  ──writes──→  traefik-dynamic volume  ──reads──→  Traefik file provider
   (uid 10001, rw)          site-<slug>.yml                     directory /config
```

`make setup` creates that volume, sets its owner to the website api's uid, and
copies this project's own `dynamic.yml` into it. The running container gets
`dynamic.yml` bind-mounted **on top** of the volume, so editing it still
hot-reloads; the copy inside the volume is the fallback for a start-up without
that bind (Traefik would otherwise read an empty mountpoint file and lose every
middleware, including `security-headers@file`).

The volume is mounted read-write here for one technical reason: runc cannot
create the mountpoint for the nested `dynamic.yml` inside a read-only mount.
Traefik never writes to it.

Nothing to do per customer — the website stack's own CLI creates and removes the
routes (`make sites CMD="create laden"`, `… CMD="reconcile"` in that repo).
Routes are derived state: if this volume is ever lost, `reconcile` rebuilds every
file from the website database.

## Project structure

```
proxy/
├── traefik/
│   ├── traefik.yml          # Static config (entrypoints web/websecure/poslicense, providers, ACME)
│   ├── config/
│   │   └── dynamic.yml      # Middlewares (ts-only, security-headers, rate-limit…),
│   │                        # legisell-internal backend transport, default TLS options.
│   │                        # Mounted INTO the traefik-dynamic volume at /config,
│   │                        # next to the customer-site routers written there.
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
| `make setup` | Create `.env` from template, initialize `acme.json`, create the `traefik-dynamic` volume |
| `make sync-config` | Copy `dynamic.yml` into that volume (fallback copy; runs inside `setup`/`up`) |
| `make up` | Start proxy in background |
| `make down` | Stop proxy |
| `make logs` | Stream Traefik logs |
| `make restart` | Restart Traefik container |
| `make gen-password` | Generate BasicAuth hash for `DASHBOARD_USERS` |

## Security notes

- `traefik/acme.json` contains Let's Encrypt private keys — keep it on the server only (`chmod 600`)
- `.env` contains secrets — never commit it
- Traefik connects to Docker via socket-proxy (read-only, `CONTAINERS`/`EVENTS`/`PING` only), not directly via `/var/run/docker.sock`
- Dashboard is Tailnet-only (`ts-only`) **and** BasicAuth over HTTPS
- Admin apps are Tailnet-only; only the public API entrypoint (`:8443`) is internet-facing, and its backend enforces its own auth
- Encoded path characters are rejected (`allowEncoded* = false`) to prevent split-view / path-allowlist bypass
- No global `insecureSkipVerify`: backend TLS is verified except the explicitly scoped internal hop (`legisell-internal@file`)
- TLS 1.2 minimum with a modern cipher suite (`tls.options.default`)
- Published container ports bypass host firewalls (UFW); keep only `:80`, `:443`, `:8443` (and SSH) reachable — never expose DB/cache ports
