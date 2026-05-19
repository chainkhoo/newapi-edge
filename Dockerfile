# syntax=docker/dockerfile:1
FROM caddy:2-alpine

LABEL org.opencontainers.image.title="newapi-edge"
LABEL org.opencontainers.image.description="Edge proxy for New API — accelerate API access without exposing the admin console"
LABEL org.opencontainers.image.source="https://github.com/chainkhoo/newapi-edge"
LABEL org.opencontainers.image.licenses="MIT"

# Default origin TLS policy: skip certificate verification on the connection
# from this edge to ORIGIN_IP. Most New API origins are fronted by Cloudflare
# and present a Cloudflare Origin Certificate that the public CA chain cannot
# verify — without this default, edge-to-origin requests would fail with
# `x509: certificate signed by unknown authority` (HTTP 502).
#
# Client-to-edge TLS is unaffected and is always strictly verified.
#
# To enable strict upstream verification (e.g. your origin has a public LE
# certificate and is not CF-proxied), override at runtime:
#   -e ORIGIN_TLS_OPTS=
ENV ORIGIN_TLS_OPTS=tls_insecure_skip_verify

# Bake the default Caddyfile into the image so `docker run` works with just env vars.
# Volume-mounting /etc/caddy/Caddyfile still overrides this for repo-clone deployments.
COPY Caddyfile /etc/caddy/Caddyfile

# Inherit caddy:2-alpine's ENTRYPOINT/CMD — already runs Caddy with this Caddyfile.
