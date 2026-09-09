#!/bin/sh
#
# Fail-closed network kill-switch.
#
# The container's filter OUTPUT chain is set to DROP by default. Only the
# following is ever allowed out:
#   - established/related traffic (responses)
#   - loopback
#   - the OpenVPN tunnel interface (tun+)
#   - the numeric address:port of the VPN server endpoint(s)  (so OpenVPN
#     itself can always connect/reconnect)
#
# If the tunnel disappears, the tunnel-interface rule simply has nothing to
# match and every other egress path is DROP - i.e. "VPN down => no
# connection". IPv6 is blocked entirely.
#
# Usage:
#   kill-switch.sh apply <endpoints-file>   # (re)build the rules
#   kill-switch.sh clear                    # restore ACCEPT policy

ENDPOINTS_FILE="${2:-/run/openvpn/endpoints}"

apply_ipv4() {
    iptables -w -F OUTPUT
    iptables -w -P OUTPUT DROP
    iptables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -w -A OUTPUT -o lo -j ACCEPT
    iptables -w -A OUTPUT -o tun+ -j ACCEPT

    # Docker's embedded DNS resolver (127.0.0.11). Query answers ultimately
    # leave through the tunnel once the default route is redirected; keeping
    # this open also lets OpenVPN re-resolve endpoints while the tunnel is
    # being re-established.
    iptables -w -A OUTPUT -d 127.0.0.11/32 -p udp --dport 53 -j ACCEPT
    iptables -w -A OUTPUT -d 127.0.0.11/32 -p tcp --dport 53 -j ACCEPT

    if [ -s "$ENDPOINTS_FILE" ]; then
        # lines are: "<proto> <ip> <port>"
        while read -r PROTO IP PORT; do
            [ -n "$IP" ] || continue
            iptables -w -A OUTPUT -d "$IP" -p "$PROTO" --dport "${PORT:-1194}" -j ACCEPT
        done < "$ENDPOINTS_FILE"
    fi
}

apply_ipv6() {
    # No IPv6 anywhere on purpose: prevents IPv6 leaks if the container is
    # ever given global v6 connectivity.
    ip6tables -w -F OUTPUT 2>/dev/null
    ip6tables -w -P OUTPUT DROP 2>/dev/null
    ip6tables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    ip6tables -w -A OUTPUT -o lo -j ACCEPT 2>/dev/null
    ip6tables -w -A OUTPUT -o tun+ -j ACCEPT 2>/dev/null
}

apply() {
    apply_ipv4 || { echo "iptables failed - are we privileged? (--cap-add NET_ADMIN or --privileged)" >&2; return 1; }
    apply_ipv6
    return 0
}

clear() {
    iptables -w -F OUTPUT 2>/dev/null
    iptables -w -P OUTPUT ACCEPT 2>/dev/null
    ip6tables -w -F OUTPUT 2>/dev/null
    ip6tables -w -P OUTPUT ACCEPT 2>/dev/null
    return 0
}

case "${1:-}" in
    apply) apply ;;
    clear) clear ;;
    *) echo "usage: $0 apply <endpoints-file> | clear" >&2; exit 2 ;;
esac
