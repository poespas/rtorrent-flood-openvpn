# syntax=docker/dockerfile:1

# rTorrent + Flood (jesec/flood v4) + OpenVPN client with a fail-closed
# network kill-switch. Built on Alpine Linux.
#
# flood is distributed as a standalone (self-contained) binary, see
# https://github.com/jesec/flood/releases
FROM alpine:3.21

ARG FLOOD_VERSION=4.16.1

LABEL org.opencontainers.image.title="rtorrent-flood-openvpn" \
      org.opencontainers.image.description="rTorrent + Flood UI behind an OpenVPN client with a network kill-switch" \
      org.opencontainers.image.source="https://github.com/poespas/rtorrent-flood-openvpn"

ENV container=docker

# Runtime dependencies
RUN apk add --no-cache \
    openvpn \
    iptables \
    ip6tables \
    iproute2 \
    rtorrent \
    screen \
    nginx \
    curl \
    ca-certificates

# Dedicated (unprivileged) user for rtorrent/flood
RUN addgroup -S rtorrent \
    && adduser -S -G rtorrent -h /home/rtorrent -s /bin/sh rtorrent \
    && mkdir -p /home/rtorrent \
    && chown -R rtorrent:rtorrent /home/rtorrent

# Install flood v4 (standalone binary; bundles Node.js)
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)  FLOOD_ASSET="flood-linux-x64" ;; \
        aarch64) FLOOD_ASSET="flood-linux-arm64" ;; \
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /usr/local/bin/flood \
        "https://github.com/jesec/flood/releases/download/v${FLOOD_VERSION}/${FLOOD_ASSET}"; \
    chmod +x /usr/local/bin/flood

# Copy root filesystem
COPY rootfs/ /

# Install nginx config and make scripts executable
RUN install -m 0644 /defaults/config/nginx/nginx.conf /etc/nginx/nginx.conf \
    &&     chmod +x \
        /usr/local/bin/supervisor \
        /usr/local/bin/prepare-config.sh \
        /usr/local/bin/kill-switch.sh \
        /usr/local/bin/move-complete.sh \
        /usr/bin/up.sh \
        /usr/bin/down.sh

VOLUME ["/config", "/output"]

EXPOSE 80 8080

CMD ["/usr/local/bin/supervisor"]
