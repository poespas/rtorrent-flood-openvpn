# rTorrent + Flood + OpenVPN

Docker container for **rTorrent** + **[Flood](https://github.com/jesec/flood)** (v4) with an
integrated **OpenVPN** client and a **fail-closed network kill-switch**.

Built on Alpine Linux. Flood v4 is installed from the official standalone
[releases](https://github.com/jesec/flood/releases) (no Node.js runtime needed).

## What it does

- At boot the container locks the network down **before** OpenVPN starts:
  the iptables `OUTPUT` chain defaults to `DROP` and only allows the VPN
  tunnel, loopback, and the (numeric) VPN server endpoint.
- OpenVPN connects, and only **after** the tunnel is up *and* verified to
  actually carry traffic (external IP reachable) does rtorrent start.
- Flood + nginx bind loopback and serve the web UI immediately.
- **If the VPN drops, the container has no connectivity at all.** Traffic
  can never fall back to the host network. The supervisor reconnects
  automatically and services resume once the tunnel is back.
- The current external (VPN) IP is written to `/config/my-external-ip.txt`
  and refreshed roughly every 60 seconds.

![FloodUI](images/1.png)

## Quick start

```bash
docker run -d \
  --name rflood \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  -p 8000:80 \
  -p 8080:8080 \
  -v /path/to/config:/config \
  -v /path/to/output:/output \
  ghcr.io/poespas/rtorrent-flood-openvpn
```

> Networking requires `CAP_NET_ADMIN` and access to `/dev/net/tun`
> (`--privileged` also works but is broader than needed).

Then:

1. Put your provider's OpenVPN config at `/path/to/config/vpn/client.conf`
   and credentials in `/path/to/config/vpn/vpn.auth` (a template is deployed
   on first run).
2. Restart the container:
   ```bash
   docker restart rflood
   ```
3. Open http://localhost:8000 in your browser.

> After changing `client.conf` (especially the server hostname) restart the
> container so the endpoint can be re-resolved and allow-listed.

## Volumes

| Volume | Description |
| :--- | :--- |
| `/path/to/config:/config` | VPN config, rtorrent state, flood data |
| `/path/to/output/incomplete:/output/incomplete` | incomplete downloads |
| `/path/to/output/complete:/output/complete` | completed downloads |

## OpenVPN

Drop in any standard `.ovpn`/`client.conf`. Notes:

- `auth-user-pass` should point at `/config/vpn/vpn.auth`.
- Deprecated/removed directives (`keysize`, `ns-cert-type`, `comp-lzo`,
  `fragment`, `block-outside-dns`, ...) are stripped automatically at boot.
- All traffic (DNS included) is forced through the tunnel
  (`redirect-gateway`), and DNS is served over the tunnel.
- The service is verified continuously; if OpenVPN dies it is restarted with
  backoff. During an outage the kill-switch guarantees **no connectivity**.

### Sonarr

Configure Sonarr with:

```
Name: rflood-openvpn
Enable: Yes
Host: <IP or HOSTNAME>
Port: 8080
Username & Password: empty
```

### Tagging

If a torrent is added with a tag set, it is copied on completion to
`/output/complete/{tag}`; otherwise `/output/complete/unsorted`.

## Flood v4

Flood is the latest jesec/flood v4 (pinned via the `FLOOD_VERSION` build
arg, defaults to the newest release). Notable changes vs. the old flood:

- **No `Torrent : Torrent` login.** Flood runs with `--auth none` and its
  rtorrent connection is pre-configured (`127.0.0.1:5000`, SCGI). If you
  expose it publicly, put an authenticating reverse proxy in front.
- Advanced options can be set through `/config/flood/flood.env`
  (`FLOOD_OPTION_*` variables, e.g. `FLOOD_OPTION_auth=default`); see the
  comments in that file or run `docker exec <name> flood --help`.

## Config layout

`/config` gets populated on first run:

| Path | Description |
| :--- | :--- |
| `vpn/client.conf`, `vpn/auth` | OpenVPN config + credentials |
| `rtorrent/rtorrent.rc` | rtorrent configuration |
| `rtorrent/session`, `rtorrent/watch`, `rtorrent/log` | rtorrent state |
| `flood/` | flood db/temp/secret + optional `flood.env` overrides |
| `my-external-ip.txt` | current external (VPN) IP, updated ~60s |

## Testing the VPN (kill-switch)

`tests/test-vpn.sh` verifies end-to-end against a **real** VPN provider.
It never stores your credentials in the repository - point it at a directory
that already contains a `vpn/client.conf` + `vpn/vpn.auth`:

```bash
tests/test-vpn.sh --config-dir /path/to/your/vpn-config
```

It checks:

- **A – VPN up:** egress goes through the VPN (container external IP differs
  from the host's), rtorrent/flood/nginx run, web UI responds.
- **B – VPN down:** the container has *no* connectivity (name resolution and
  direct-IP connections both fail) while the local web UI stays reachable.
- **C – recovery:** the supervisor reconnects automatically and egress
  resumes through the VPN.

## Releases

A GitHub Action builds and publishes the image **monthly** (and on manual
`workflow_dispatch`) to:

- GHCR: `ghcr.io/poespas/rtorrent-flood-openvpn` (`latest` + `vYYYY.MM[.n]`)
- A tagged GitHub Release with the pinned flood version and image digest.

## License

GPL v3.0, see [LICENSE](LICENSE).
