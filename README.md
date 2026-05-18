# newapi-edge

> A drop-in edge node for [New API](https://github.com/Calcium-Ion/new-api) — accelerate API access for users in regions with poor connectivity to your origin server, **without exposing the admin console or management API**.

English · [中文](./README.zh-CN.md)

---

## What it does

`newapi-edge` is a single-container Caddy reverse proxy that you deploy on a VPS with a good network route to your target users (e.g. a Hong Kong / Tokyo / Singapore node for mainland-China users whose path to your origin is slow or lossy).

- **Forwards only API endpoints** — `/v1/*`, `/v1beta/*`, `/mj/*`, `/suno/*`, etc. Every other path returns 404, so the admin UI, login page, and `/api/*` management endpoints stay hidden behind the origin.
- **Bypasses any CDN in front of your origin** — connects directly to the origin's real IP while keeping `Host` and TLS SNI set to the public hostname, so the origin's vhost routing and HTTPS certificate continue to work as if traffic came through the CDN.
- **Streaming-aware** — `flush_interval -1` and 600s read/write timeouts mean SSE and long LLM completions are not buffered or truncated.
- **Auto HTTPS** — Caddy obtains and renews a Let's Encrypt certificate for the edge hostname with zero configuration.
- **Drop-in portable** — three files (`docker-compose.yml`, `Caddyfile`, `.env`). Move the directory to another VPS, edit `.env`, run `docker compose up -d`.

## Architecture

```
                            ┌───────────────────────────────┐
  Users in slow region  ──► │  newapi-edge VPS (this repo)  │ ──► Origin's real IP
                            │  Caddy reverse proxy          │     (Host & SNI rewritten
                            │  - path allowlist             │      back to ORIGIN_HOST,
                            │  - SSE streaming              │      so origin vhost +
                            │  - auto HTTPS                 │      certificate still match)
                            └───────────────────────────────┘
```

Why this works: clients hit `CHILD_DOMAIN` (DNS A record points to the edge VPS). The edge opens a TCP/TLS connection to `ORIGIN_IP:443` and presents `ORIGIN_HOST` as the SNI / Host header. The origin's web server sees a normal request for `ORIGIN_HOST` and routes it to New API as usual.

## Installation

Two equally-supported deployment methods — both produce the same running service. Pick based on whether you want to customise the path allowlist.

|  | Method A · Docker Compose | Method B · Pre-built image |
|---|---|---|
| **Best for** | Customising `Caddyfile`; version-controlling your config | Fastest first deploy; no source checkout |
| **Requires** | `git` + Docker + Compose plugin | Docker only |
| **Image source** | Pulls `caddy:2-alpine`, mounts your local `Caddyfile` | Pulls `ghcr.io/chainkhoo/newapi-edge:<tag>` with `Caddyfile` baked in |
| **Customising paths** | Edit `Caddyfile` → `docker compose restart caddy` | Fork the repo (CI rebuilds your image), or switch to Method A |
| **Updating** | `git pull && docker compose pull && docker compose up -d` | `docker pull … && docker rm -f … && docker run …` |

### Common prerequisites (both methods)

- A VPS with public IPv4, ports **80 + 443/TCP and 443/UDP** open to the internet
- Docker Engine ≥ 20.10
- A DNS A record you control, pointing at this VPS — **not** proxied through any CDN (Cloudflare users: grey-cloud / "DNS only")
- A New API origin you control, reachable at its real IP via HTTPS with a valid certificate for its public hostname

---

### Method A — Docker Compose

```bash
# 1. Clone the repo
git clone https://github.com/chainkhoo/newapi-edge.git
cd newapi-edge

# 2. Configure
cp .env.example .env
$EDITOR .env       # fill in CHILD_DOMAIN, ORIGIN_IP, ORIGIN_HOST, ACME_EMAIL, NODE_NAME

# 3. Point DNS
#    A record:  <CHILD_DOMAIN>  →  <this VPS's IPv4>     (DNS only, no CDN proxy)

# 4. Launch
docker compose up -d

# 5. Watch certificate issuance (~30 seconds)
docker compose logs -f caddy
#    Look for "certificate obtained successfully"

# 6. Verify
curl -sS https://<CHILD_DOMAIN>/v1/models     # → JSON from New API
curl -sS https://<CHILD_DOMAIN>/              # → 404  (admin UI blocked)
curl -sS https://<CHILD_DOMAIN>/healthz       # → "ok"
```

**Day-to-day operations:**

```bash
# Tail live logs
docker compose logs -f caddy
tail -f logs/access.log

# Hot-reload after editing Caddyfile (zero downtime)
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# Update Caddy
docker compose pull && docker compose up -d

# Stop / restart
docker compose down
docker compose up -d
```

---

### Method B — Pre-built image (`docker run`)

A multi-arch image (`linux/amd64` + `linux/arm64`) is built and published to GHCR on every push to `main` and every `v*` tag.

```bash
# 1. Create named volumes (persists Let's Encrypt certs across container recreations)
docker volume create newapi_edge_data
docker volume create newapi_edge_config

# 2. Point DNS
#    A record:  api-cn.example.com  →  <this VPS's IPv4>     (DNS only, no CDN proxy)

# 3. Run the container
docker run -d \
  --name newapi-edge \
  --restart unless-stopped \
  -p 80:80 -p 443:443 -p 443:443/udp \
  -v newapi_edge_data:/data \
  -v newapi_edge_config:/config \
  -e CHILD_DOMAIN=api-cn.example.com \
  -e ORIGIN_IP=203.0.113.10 \
  -e ORIGIN_HOST=api.example.com \
  -e ACME_EMAIL=you@example.com \
  -e NODE_NAME=edge-1 \
  ghcr.io/chainkhoo/newapi-edge:latest

# 4. Watch certificate issuance (~30 seconds)
docker logs -f newapi-edge

# 5. Verify
curl -sS https://api-cn.example.com/v1/models     # → JSON from New API
curl -sS https://api-cn.example.com/              # → 404
curl -sS https://api-cn.example.com/healthz       # → "ok"
```

**Day-to-day operations:**

```bash
# Tail live logs
docker logs -f newapi-edge

# Update to a new image (state persists in named volumes)
docker pull ghcr.io/chainkhoo/newapi-edge:latest
docker rm -f newapi-edge
docker run -d ...   # same command as install step 3

# Stop / restart
docker stop newapi-edge
docker start newapi-edge
```

**Available image tags:**

| Tag | Meaning |
|---|---|
| `:latest` | Tip of `main`, rebuilt on every commit to that branch |
| `:X.Y.Z` | Specific release version (e.g. `:0.1.1`) — **recommended for production** |
| `:X.Y` | Minor track — automatically follows `X.Y.*` releases |
| `:X` | Major track — automatically follows `X.*.*` releases |
| `:sha-<short>` | Pinned to a specific commit |

Production tip: pin to a specific `X.Y.Z` and update intentionally rather than chasing `:latest`.

## Configuration reference

All runtime configuration lives in `.env`:

| Variable | Purpose | Example |
|---|---|---|
| `CHILD_DOMAIN` | Public hostname users will hit on this edge | `api-cn.example.com` |
| `ORIGIN_IP` | Origin server's real public IPv4 | `203.0.113.10` |
| `ORIGIN_HOST` | Public hostname your New API is normally served as | `api.example.com` |
| `ACME_EMAIL` | Email for Let's Encrypt registration / expiry notices | `you@example.com` |
| `NODE_NAME` | Label sent as `X-Origin-Node` header | `hk-1` |

The path allowlist is defined in `Caddyfile`. Defaults cover the common New API vendors (OpenAI, Gemini, Anthropic-style, Midjourney, Suno, Luma, SD, etc.). If your New API instance enables additional vendor routes, add them to the `@api` matcher and `docker compose restart caddy`.

## Securing the origin (recommended)

By default, anyone who learns your origin's real IP can still send requests directly to it, bypassing the edge. To force traffic through your edge nodes:

1. **Firewall the origin's port 443** so it only accepts connections from your edge node IPs (plus your existing CDN's IP ranges if you keep one in front for fallback traffic). With UFW:
   ```bash
   ufw allow from <edge-vps-ip> to any port 443 proto tcp
   # ...repeat for each edge node and CDN range...
   ufw deny 443/tcp
   ```
2. **Optional**: Have the origin's reverse proxy require a shared secret header that the edge injects. Add to your origin's nginx/Caddy config a check for `X-Origin-Node` (or any custom header your edge adds) and reject requests missing it.

## Operating multiple edge nodes

Same repo, same `Caddyfile`, different `.env` per VPS:

```bash
# On each node
cp .env.example .env
# Edit: NODE_NAME=hk-1 / jp-tokyo / us-la …
docker compose up -d
```

Then use any GeoDNS / smart-resolution service (Cloudflare load balancer with geo steering, DNSPod, NS1, etc.) to route users to the nearest edge by region or ISP.

## Switching to a different VPS (zero downtime)

```bash
# On the new VPS
git clone <repo> && cd newapi-edge && cp .env.example .env && $EDITOR .env
docker compose up -d                   # certificate issues in ~30s

# Once the new edge is healthy:
#   - Update DNS A record to point to the new VPS IP
#   - Wait for TTL to expire (set TTL=300s in advance for faster cutover)
#   - Decommission the old VPS:  docker compose down
```

DNS-based cutover means both edges serve in parallel during the switch — no downtime.

## Operations

```bash
# View live logs (Caddy stdout + structured access log)
docker compose logs -f caddy
tail -f logs/access.log

# Reload after editing Caddyfile (no restart, zero-downtime config change)
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# Update Caddy image
docker compose pull && docker compose up -d

# Stop / start
docker compose down
docker compose up -d
```

## Troubleshooting

**Certificate not issuing**
- DNS A record must point at this VPS *before* `docker compose up -d`, and must not be CDN-proxied.
- Port 80 must be reachable from the internet (Let's Encrypt's HTTP-01 challenge).
- Check logs: `docker compose logs caddy | grep -i acme`.

**502 / connection refused from origin**
- `ORIGIN_IP` reachable from this VPS? Try: `docker compose exec caddy wget -qO- https://<ORIGIN_IP> --header="Host: <ORIGIN_HOST>"`.
- Origin firewall: if you've allowlisted IPs, add this VPS's IP.

**404 on a legitimate endpoint**
- Your New API may use a vendor path not in the default allowlist. Add it to the `@api` matcher in `Caddyfile` and reload.

**Streaming responses cut off / buffered**
- Confirm `flush_interval -1` is present in `Caddyfile` (it is by default).
- Some upstream CDNs in front of the origin may force buffering. Connecting to `ORIGIN_IP` directly (this project's default) avoids that.

## FAQ

**How does this compare to New API's official master/slave cluster deployment?**

They solve different problems:

- **Official cluster** (master + slave nodes + shared MySQL/Redis) solves **insufficient single-machine throughput** — horizontal scaling for processing capacity. All nodes share the same database and Redis.
- **newapi-edge** (this project) solves **network latency** — a CDN-style edge for users with a slow path to your origin. The edge touches no business data.

For *geographic acceleration* — speeding up a specific region's access — the official cluster is **not simpler, and often slower and riskier**:

| Aspect | Official cluster | newapi-edge |
|---|---|---|
| Components required on the edge node | Full new-api container + must reach origin MySQL + must reach origin Redis | Single Caddy container, zero business dependencies |
| Cross-region latency impact | ❌ Severe — each LLM request triggers 5–10 cross-region DB round-trips (lookup user/token/channel, write log, deduct/refund quota, etc.), 150 ms+ each, **adding 1–2 seconds per request** | ✅ One cross-region hop only (request is forwarded whole to the origin, all DB work happens locally there) |
| Config-change propagation | 60 s sync interval by default (channel edits, user changes, quota tweaks all take time to land) | Instant — the edge caches no business state |
| Admin UI exposure | Open by default (slave nodes serve the same UI) | 404 by default (path allowlist only forwards API endpoints) |
| Blast radius if edge node is compromised | DB password + `SESSION_SECRET` / `CRYPTO_SECRET` leak → entire origin dataset exposed | Edge VPS discarded, origin unaffected |
| Network attack surface | Origin MySQL + Redis must be reachable from every edge (public IP or VPN) | Origin only needs 443 reachable from edge IPs (can be tightened with an allowlist) |
| Adding / removing nodes | Edit LB upstream, clean up node state in Redis | DNS change + `docker compose down` |

**The crux is database location**: the official cluster requires all nodes to share one database. That means every LLM request from an edge node crosses the network multiple times to query the origin's DB — and those round-trips **eat up (or exceed) the latency savings** the edge was supposed to provide.

The two approaches can be **stacked**: run the official master/slave cluster in the origin region for throughput, and put newapi-edge in remote regions for latency. But if your goal is purely "make region X faster", this project is the right tool.

**When should you use the official cluster instead?**
- Origin CPU/memory is saturated and you need multi-node throughput
- All nodes live in the same datacenter or region (shared low-latency DB)
- Goal is high availability, not geographic acceleration

---

**Why Caddy and not Nginx?**  Caddy ships with automatic Let's Encrypt and reasonable defaults for streaming proxies, so the whole thing fits in ~80 lines of `Caddyfile` with no certbot/cron plumbing. If you'd rather use Nginx, the same logic ports over in about the same amount of YAML.

**Does this work for non–New-API backends?**  Yes — anything with a stable set of path prefixes works. Just edit the `@api` matcher.

**Can I run the edge behind Cloudflare for DDoS protection?**  You can, but the *point* of this edge is usually to bypass CDN routing for users where CDN edges are slow. If you want both, run two records — `CHILD_DOMAIN` (grey-cloud, direct to edge) for users who benefit from the edge, and your existing CDN-fronted hostname for everyone else.

## Contributing

PRs welcome. Particularly useful additions:
- Path-allowlist presets for forks of New API.
- Examples of GeoDNS configuration with common providers.
- A non-Caddy variant (HAProxy, Nginx, Traefik) for users who already operate one of those.

## License

MIT — see [LICENSE](./LICENSE).

`newapi-edge` is not affiliated with the New API project. New API is © its respective authors.
