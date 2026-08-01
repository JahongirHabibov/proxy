# Traefik is shared infrastructure

One Traefik instance fronts every web service on this host: customer websites,
the LEGISELL control plane, the POS licence API, the APT repository, the remote
desktop gateway, several static sites. They belong to different projects, are
deployed at different times by different people, and none of them can see the
others.

That is the point of the proxy, and it is also its hazard. **A change to a shared
object changes every consumer at once, without any of them being redeployed.**
Both outages on 2026-07-31 came from exactly that, and in both cases the change
looked local to whoever made it.

This document exists so the next change does not.

---

## What is shared, what is private

| Object | Where | Blast radius |
|---|---|---|
| Entrypoints (`web`, `websecure`, `poslicense`) | `traefik/traefik.yml` | **every router** |
| Middlewares in `dynamic.yml` (`security-headers`, `compress`, `rate-limit`, `rate-limit-strict`, `ts-only`, `www-redirect`) | `traefik/config/dynamic.yml` | **every router that names them** |
| TLS options (`tls.options.default`) | `dynamic.yml` | **every HTTPS router** |
| The `letsencrypt` resolver and `acme.json` | `traefik.yml`, host file | **every certificate** |
| Published ports 80 / 443 / 8443 | `docker-compose.yml` | **everything reachable from outside** |
| Network `proxy-network` | `docker-compose.yml` | every app container attached to it |
| Volume `traefik-dynamic` | shared with `retail-website-template` | the file-provider directory itself |
| `tailscaled` on the host | not in any repo | every tailnet-gated router |
| | | |
| A project's own routers, services, middlewares | that project's labels | that project only |

Rule of thumb: **if it lives in this repository, assume it is shared.** The
per-project objects live in the projects.

---

## Consumer inventory

Regenerate before touching a middleware — this table is a snapshot, not a
contract:

```bash
cd ~/projects/proxy/external_repos
for mw in security-headers compress rate-limit rate-limit-strict ts-only www-redirect legisell-internal; do
  printf '%-20s ' "$mw"
  grep -rl "$mw@file" --include=*.yml . | sed 's|^\./||;s|/docker-compose.*||' | tr '\n' ' '
  echo
done
```

As measured on 2026-08-01:

| Middleware | Consumers |
|---|---|
| `security-headers@file` | saas-online-ordering, abdullojon, apt, legisell-deployment, remote-control, about-me, pos-public-website, **retail-website-template (every customer site)** |
| `compress@file` | remote-control, pos-public-website, abdullojon, legisell-deployment, saas-online-ordering, about-me, **retail-website-template** |
| `rate-limit@file` | saas-online-ordering, abdullojon, apt, legisell-deployment, remote-control, **retail-website-template** |
| `rate-limit-strict@file` | remote-control, apt, the Traefik dashboard, the website provisioning surface |
| `www-redirect@file` | abdullojon, saas-online-ordering, about-me, pos-public-website |
| `ts-only@file` | nobody today (`legisell-ts-only` is defined in legisell-deployment's own labels) |
| `legisell-internal@file` | legisell-deployment (serversTransport) |

The customer websites do not appear in a grep of `external_repos`: their routers
are generated at runtime into the `traefik-dynamic` volume by
`retail-website-template`. **Check that project too.** Its template lives in
`docker/backend/app/services/traefik_config.py`.

---

## Rules for changing anything shared

### 1. Take the inventory first

Never from memory. Run the loop above and read the list of projects you are about
to affect.

### 2. Measure the behaviour, do not reason about it

Traefik's semantics are not always what the option name suggests. Two examples
from this repository, both of which survived review by argument and only fell to
a test:

* `rate-limit` carried `sourceCriterion.ipStrategy.depth: 1`. The stated reason
  for removing it was "a client can forge X-Forwarded-For and bypass the limit".
  **That is false** — Traefik overwrites inbound forwarded headers unless an
  entrypoint declares `forwardedHeaders.trustedIPs`, and none here does. The real
  defect was the opposite: with no such header present, `depth: 1` produces an
  empty key, so every visitor of a site shared **one** 100 req/s bucket.
* A router written by the file provider referenced `service: website-web`.
  Traefik resolves an unqualified name inside the provider that supplied it, so
  it looked for `website-web@file` while the service came from container labels.
  Every customer site answered 404 behind the default certificate.

A local testbed takes five minutes and settles the question:

```bash
# traefik + traefik/whoami on a throwaway network, the middleware under test,
# then two containers on that network sending bursts in parallel so their
# source addresses differ. Compare "allowed" counts per client.
```

The rate-limit result, for the record:

```
depth: 1            → client A 0 allowed, client B 2   (one shared bucket)
no sourceCriterion  → client A 2 allowed, client B 2   (one bucket per client)
```

### 3. Roll out through `make up`

```bash
cd ~/projects/proxy && git pull && make up
```

`dynamic.yml` is bind-mounted and watched: middleware and TLS changes take effect
**without restarting Traefik**, so no connection is dropped. Only a change to
`docker-compose.yml` that touches the Traefik service itself recreates the
container.

**Never `docker compose up -d --remove-orphans` here.** It deletes containers this
compose file does not define, which is how the tailnet node was lost on
2026-07-31. `make up` refuses to start when a foreign container holds port 80 and
names the safe, explicit removal instead.

### 4. Verify every consumer class, not just the one you care about

See the checklist below.

### 5. Know the rollback before you start

```bash
git revert <commit> && make up
```

For a `dynamic.yml`-only change this is a hot reload: seconds, no downtime.

---

## Verification checklist after any proxy change

Run all of it. Each line stands for a class of consumer that the others do not
cover.

```bash
# 1. Traefik parsed everything — no dropped routers
docker logs --since 3m traefik 2>&1 | grep -iE "error|does not exist" || echo "clean"

# 2. A plain public site (security-headers + compress + rate-limit)
curl -sI https://<a-public-site> | head -1                    # 200

# 3. A customer website from the generated file provider
docker exec traefik ls /config/                               # dynamic.yml + site-*.yml
cd ~/retail-website-template && make sites CMD="list"

# 4. The POS licence API on its own entrypoint (port 8443, NOT tailnet-gated)
curl -sI https://api.legisell.de:8443/health | head -1

# 5. The tailnet-gated admin UI — from a tailnet device
curl -sI https://admin.legisell.de | head -1                  # 200
#    and from anywhere else it must stay refused:
curl -sI --resolve admin.legisell.de:443:<public-ip> https://admin.legisell.de | head -1   # 403

# 6. The dashboard (BasicAuth, no tailnet gate by decision)
curl -sI https://proxy.legisell.de | head -1                  # 401

# 7. Certificates still renewing
docker logs --since 10m traefik 2>&1 | grep -i acme | grep -i error || echo "no ACME errors"

# 8. After a pull that changed dynamic.yml: is the bind mount still live?
#    `traefik/config/dynamic.yml` is bind-mounted as a single FILE, and a file
#    bind mount pins an inode. git replaces the file rather than editing it, so
#    the running container can end up reading a stale inode — edits would then
#    stop hot-reloading, silently, until the next container recreation.
echo "# probe $(date +%s)" >> traefik/config/dynamic.yml
sleep 3
docker exec traefik tail -1 /config/dynamic.yml       # must show the probe line
sed -i '$d' traefik/config/dynamic.yml                # remove it again
```

If the probe does not appear, the mount is stale. Recreate just this container —
no other service is touched, and published ports return within a second:

```bash
docker compose up -d --force-recreate traefik
```

If a step cannot be run, say so in the change notes rather than assuming it
passes. A checklist with an unmarked box is information; a checklist ticked
without running it is worse than none.

---

## Host-level dependencies that no repository captures

These are invisible to `git`, survive no reinstall, and each one has already
caused an outage or came within one step of it.

### `tailscaled` — running, logged in, and NOT masquerading

```bash
systemctl status tailscaled          # active
tailscale status                     # a node, not "Stopped"
tailscale debug prefs | grep NoSNAT  # "NoSNAT": true   ← load bearing
```

`admin.legisell.de` is gated by `legisell-ts-only`, an `ipAllowList` on
`100.64.0.0/10`. For that to mean anything, Traefik has to *see* the tailnet
address of the caller.

By default `tailscaled` masquerades traffic it forwards out of the tailnet into a
local subnet — and a Docker bridge is such a subnet. The request then reaches
Traefik as `172.20.0.1`, the bridge gateway, and the allowlist refuses every
tailnet client. `tailscale set --snat-subnet-routes=false` turns that off; the
reply path stays intact because conntrack reverses the DNAT before the packet
leaves and the host itself routes `100.64.0.0/10`.

**This setting is not persisted by any file in any repository.** A later
`tailscale up` with a different flag set resets it, and the symptom is a 403 that
looks exactly like a correctly working allowlist. `make up` therefore checks it.

It also explains why the gate worked before 2026-07-30: Traefik then shared the
tailscale sidecar's network namespace, so `tailscale0` was its own interface and
no NAT sat in between. **The allowlist depended on the sidecar shape, not merely
on the node existing.**

### DNS records that point into the tailnet

`admin.legisell.de` resolves to `100.69.235.112` — a CGNAT address, unroutable
from the public internet. That is the first layer of protection; the allowlist is
the second. It also means the record has to be corrected whenever the node's
tailnet address changes, and `TAILSCALE_LOCAL_IP` in `legisell-deployment/.env`
along with it.

Do not pin these names in `/etc/hosts` on workstations. A pin hides the real
state: on 2026-08-01 a stale pin made a working DNS change look broken, and
flushing caches could not help because a pin is not a cache.

### Docker

`/etc/docker/daemon.json` governs whether the userland proxy sits in the path.
Changing it restarts the daemon and therefore every container on the host.

---

## Known non-obvious facts, all measured

| Fact | Consequence |
|---|---|
| A router from the file provider resolves unqualified service names within `@file` | generated routers must write `service: website-web@docker` |
| `sourceCriterion.ipStrategy.depth: 1` with no `X-Forwarded-For` yields an empty key | one shared rate-limit bucket for all clients |
| Traefik overwrites inbound `X-Forwarded-*` unless `forwardedHeaders.trustedIPs` is set | forging that header does not bypass anything here |
| Let's Encrypt refuses any name without a dot | a `Host(localhost)` router orders forever and burns the account's order budget |
| `tailscaled` masquerades forwarded tailnet traffic by default | `ipAllowList` on `100.64.0.0/10` sees the bridge gateway instead |
| `docker logs traefik` returns the whole history | grep for errors with `--since`, or every old error looks current |
| `cp` truncates its destination before writing | a reader landing in that gap sees an empty config and every `@file` middleware disappears at once — write to `.tmp` and `mv` |
| A bind mount of a single FILE pins an inode | `git pull` replaces the file, so the container may keep reading the old one — or fall through to whatever the parent mount holds. Probe after every pull (below) |
