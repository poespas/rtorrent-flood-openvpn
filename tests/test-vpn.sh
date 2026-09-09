#!/usr/bin/env bash
#
# End-to-end VPN test for the rtorrent-flood-openvpn image.
#
# Verifies, against a real VPN provider:
#   A) with the tunnel UP:    the container has working connectivity that
#                             egresses through the VPN (external IP differs
#                             from the host's) and rtorrent/flood/nginx run;
#   B) with the tunnel DOWN:  the container has NO connectivity (fail-closed
#                             kill-switch) while the local web UI stays up;
#   C) recovery:              when the VPN process is restored the container
#                             reconnects on its own.
#
# The provider config (client.conf + vpn.auth and any referenced cert files)
# is supplied via --config-dir and never committed to this repository.
#
# Usage:
#   tests/test-vpn.sh --config-dir /path/to/my/vpn-config [options]
#
# Options:
#   -c, --config-dir DIR   dir containing vpn/client.conf + vpn/auth (required)
#   -i, --image NAME       image tag to build & run   [default: rtorrent-flood-openvpn:test]
#   -n, --name NAME        docker container name       [default: rflood-vpn-test]
#   -p, --port PORT        host port for the web UI    [default: 8000]
#   -s, --skip-build       use an already-built image
#   -k, --keep             keep container + config on failure (for debugging)
#   -v, --verbose          print container logs on failure

set -uo pipefail

IMAGE="rtorrent-flood-openvpn:test"
NAME="rflood-vpn-test"
PORT="8000"
CONFIG_DIR=""
SKIP_BUILD=0
KEEP=0
VERBOSE=0
TUNNEL_TIMEOUT=240

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config-dir) CONFIG_DIR="$2"; shift 2 ;;
        -i|--image)      IMAGE="$2";       shift 2 ;;
        -n|--name)       NAME="$2";        shift 2 ;;
        -p|--port)       PORT="$2";        shift 2 ;;
        -t|--tunnel-timeout) TUNNEL_TIMEOUT="$2"; shift 2 ;;
        -s|--skip-build) SKIP_BUILD=1;     shift ;;
        -k|--keep)       KEEP=1;           shift ;;
        -v|--verbose)    VERBOSE=1;        shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CONFIG_DIR" ] || { echo "error: --config-dir is required" >&2; exit 2; }
[ -r "$CONFIG_DIR/vpn/client.conf" ] || { echo "error: $CONFIG_DIR/vpn/client.conf not found" >&2; exit 2; }
[ -r "$CONFIG_DIR/vpn/vpn.auth" ] || { echo "error: $CONFIG_DIR/vpn/vpn.auth not found" >&2; exit 2; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/rflood-test.XXXXXX)"
UI_URL="http://127.0.0.1:${PORT}/"
PASS=0; FAIL=0
declare -a FAILURES=()

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1
    if [ "$KEEP" -eq 1 ]; then
        echo "[info] keeping container/config: name=$NAME config=$WORK"
    else
        # the container chowns /config to its internal rtorrent user, which
        # maps to an arbitrary uid on the host - hand ownership back first
        docker run --rm -v "$WORK:/data" alpine:3.21 \
            chown -R "$(id -u):$(id -g)" /data >/dev/null 2>&1
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$*"); echo "  FAIL: $*"; }
die()  { bad "$*"; exit 1; }

step() { echo; echo "=== $* ==="; }

container_exec() { docker exec "$NAME" "$@"; }

external_ip_host() { curl -4 -fsS --max-time 10 https://ifconfig.co/ip 2>/dev/null; }

# container external IP via the tunnel ("" => unreachable)
external_ip_container() {
    container_exec curl -4 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
}

wait_for() { # wait_for <timeout_seconds> <description> <cmd...>
    local timeout="$1" desc="$2"; shift 2
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2; i=$((i + 2))
    done
    echo "  [timed out after ${timeout}s waiting for: $desc]" >&2
    return 1
}

# ---------------------------------------------------------------------------

step "Environment"
echo "  image:      $IMAGE"
echo "  container:  $NAME"
echo "  web UI:     http://127.0.0.1:${PORT}/"
echo "  config dir: $CONFIG_DIR"

if [ "$SKIP_BUILD" -eq 0 ]; then
    step "Build image"
    docker build -t "$IMAGE" "$REPO_DIR" || die "docker build failed"
fi

# stage config (never in the repo)
step "Stage config"
cp -r "$CONFIG_DIR/." "$WORK/"
chmod -R u+rw "$WORK"
echo "  staged to $WORK"

HOST_IP="$(external_ip_host)"
echo "  host external IPv4: ${HOST_IP:-<unavailable>}"

step "A. Start container and connect VPN"
docker rm -f "$NAME" >/dev/null 2>&1
docker run --rm --privileged --name "$NAME" -d \
    -v "$WORK:/config" \
    -p "${PORT}:80" \
    "$IMAGE" >/dev/null || die "docker run failed"

wait_for "$TUNNEL_TIMEOUT" "VPN tunnel (external IP file)" \
    test -f "$WORK/my-external-ip.txt" \
    || { [ "$VERBOSE" -eq 1 ] && docker logs "$NAME"; die "VPN never came up"; }

CONTAINER_IP=""
for _ in 1 2 3 4; do
    CONTAINER_IP="$(external_ip_container)"
    [ -n "$CONTAINER_IP" ] && break
    sleep 3
done
echo "  container external IPv4: ${CONTAINER_IP:-<none>}"

if [ -n "$CONTAINER_IP" ] && [ -n "$HOST_IP" ] && [ "$CONTAINER_IP" != "$HOST_IP" ]; then
    ok "egress is via the VPN (container ${CONTAINER_IP} != host ${HOST_IP})"
else
    [ -n "$CONTAINER_IP" ] && [ "$CONTAINER_IP" = "$HOST_IP" ] \
        && bad "possible LEAK: container egress == host external IP" \
        || bad "could not determine egress IPs (container='${CONTAINER_IP}' host='${HOST_IP}')"
fi

echo "  supervisor log:"
docker logs "$NAME" 2>&1 | grep -E "external IP|rtorrent started|starting" | tail -4 | sed 's/^/    /'

wait_for 60 "rtorrent" container_exec pgrep -f /usr/bin/rtorrent \
    && ok "rtorrent started (after tunnel was up)" \
    || bad "rtorrent not running"

container_exec pgrep -f /usr/local/bin/flood >/dev/null 2>&1 && ok "flood running" || bad "flood not running"

UI_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$UI_URL")
[ "$UI_CODE" = "200" ] && ok "web UI reachable (HTTP 200)" || bad "web UI returned HTTP ${UI_CODE}"

# ---------------------------------------------------------------------------

step "B. VPN outage => no connectivity (kill-switch)"
container_exec sh -c 'kill -STOP 1' || die "could not pause supervisor"
container_exec pkill -x openvpn || die "could not kill openvpn"
sleep 8

container_exec sh -c 'ls -d /sys/class/net/tun* >/dev/null 2>&1' \
    && echo "  [warn] tun interface still present" || echo "  tunnel interface is gone"

if container_exec curl -4 -sS --max-time 8 https://ifconfig.co/ip >/dev/null 2>&1; then
    bad "egress still works while VPN is down (LEAK)"
else
    ok "no outbound connectivity while VPN is down (curl failed)"
fi

if container_exec curl -4 -sS --max-time 8 http://1.1.1.1/ -o /dev/null >/dev/null 2>&1; then
    bad "direct-IP egress still works while VPN is down (LEAK)"
else
    ok "direct-IP egress blocked while VPN is down (no DNS reliance)"
fi

UI_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$UI_URL")
[ "$UI_CODE" = "200" ] && ok "local web UI still served during outage" || bad "web UI down during outage (HTTP ${UI_CODE})"

# ---------------------------------------------------------------------------

step "C. Recovery"
container_exec sh -c 'kill -CONT 1' || die "could not resume supervisor"

RECONNECTED=0
CONTAINER_IP2=""
i=0
while [ "$i" -lt 120 ]; do
    CONTAINER_IP2="$(external_ip_container)"
    if [ -n "$CONTAINER_IP2" ] && [ "$CONTAINER_IP2" != "$HOST_IP" ]; then
        RECONNECTED=1
        break
    fi
    sleep 3; i=$((i + 3))
done

if [ "$RECONNECTED" -eq 1 ]; then
    ok "VPN reconnected automatically"
else
    [ "$VERBOSE" -eq 1 ] && docker logs "$NAME"
    bad "VPN did not reconnect"
fi
echo "  container external IPv4 (after reconnect): ${CONTAINER_IP2:-<none>}"
[ "$RECONNECTED" -eq 1 ] \
    && ok "egress again via the VPN after reconnect" \
    || bad "egress not via VPN after reconnect"

wait_for 60 "rtorrent (still healthy)" container_exec pgrep -f /usr/bin/rtorrent \
    && ok "rtorrent healthy after reconnect" \
    || bad "rtorrent down after reconnect"

# ---------------------------------------------------------------------------

step "Result"
echo "  passed: $PASS   failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  failures:\n'
    for f in "${FAILURES[@]}"; do echo "    - $f"; done
    echo
    echo "  Last supervisor log lines:"
    docker logs "$NAME" 2>&1 | tail -20 | sed 's/^/    /'
    exit 1
fi
echo "  ALL CHECKS PASSED"
exit 0
