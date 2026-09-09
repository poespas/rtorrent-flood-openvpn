#!/bin/sh
# Called by OpenVPN when the tunnel goes down.
# Restore the container's original resolver (Docker's embedded DNS).

if [ -e /etc/resolv.conf.openvpn.bak ]; then
    cat /etc/resolv.conf.openvpn.bak > /etc/resolv.conf
    rm -f /etc/resolv.conf.openvpn.bak
fi

exit 0
