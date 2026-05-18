# syntax=docker/dockerfile:1
FROM caddy:2-alpine

LABEL org.opencontainers.image.title="newapi-edge"
LABEL org.opencontainers.image.description="Edge proxy for New API — accelerate API access without exposing the admin console"
LABEL org.opencontainers.image.source="https://github.com/chainkhoo/newapi-edge"
LABEL org.opencontainers.image.licenses="MIT"

# Bake the default Caddyfile into the image so `docker run` works with just env vars.
# Volume-mounting /etc/caddy/Caddyfile still overrides this for repo-clone deployments.
COPY Caddyfile /etc/caddy/Caddyfile

# Inherit caddy:2-alpine's ENTRYPOINT/CMD — already runs Caddy with this Caddyfile.
