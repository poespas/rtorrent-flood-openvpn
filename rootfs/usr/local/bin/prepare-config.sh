#!/bin/sh
#
# Prepare the /config and /output volumes on first boot:
#   - deploy example configs when absent
#   - create the directory layout rtorrent/flood expect
#   - fix ownership/permissions

set -e

# --- OpenVPN ---------------------------------------------------------------
mkdir -p /config/vpn
if [ ! -f /config/vpn/client.conf ]; then
    cp /defaults/config/vpn/client.conf /config/vpn/client.conf
    chmod 600 /config/vpn/client.conf
fi
if [ ! -f /config/vpn/vpn.auth ]; then
    cp /defaults/config/vpn/vpn.auth /config/vpn/vpn.auth
    chmod 600 /config/vpn/vpn.auth
fi

# --- rTorrent + Flood ------------------------------------------------------
rm -f /config/rtorrent/session/rtorrent.lock

mkdir -p /output/incomplete
mkdir -p /output/complete
mkdir -p /config/rtorrent/session
mkdir -p /config/rtorrent/log
mkdir -p /config/rtorrent/watch/load
mkdir -p /config/rtorrent/watch/start
mkdir -p /config/flood

if [ ! -f /config/rtorrent/rtorrent.rc ]; then
    cp /defaults/config/rtorrent/rtorrent.rc /config/rtorrent/rtorrent.rc
    chown rtorrent:rtorrent /config/rtorrent/rtorrent.rc
fi

# Sample flood env override (advanced). Flood v4 configures everything via
# FLOOD_OPTION_* env vars; see /usr/local/bin/supervisor for defaults.
if [ ! -f /config/flood/flood.env ]; then
    cp /defaults/config/flood/flood.env /config/flood/flood.env
fi

# --- Ownership -------------------------------------------------------------
chown -R rtorrent:rtorrent /config
chown -R rtorrent:rtorrent /output
