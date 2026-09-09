#!/bin/sh
# Called by OpenVPN once the tunnel is established.
# Point DNS at public resolvers whose traffic must traverse the tunnel
# (the supervisor forces redirect-gateway def1, so these are only reachable
# over tunX -> no DNS leak and no dependency on provider-pushed DNS).

BACKUP=/etc/resolv.conf.openvpn.bak

if [ -e /etc/resolv.conf ]; then
    cp /etc/resolv.conf "$BACKUP"
fi

cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
options timeout:2 attempts:2
EOF

exit 0
