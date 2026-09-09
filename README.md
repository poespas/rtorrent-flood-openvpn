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

## User IDs and permissions

The container's **PID 1 runs as root** because OpenVPN must create the tun
device and apply the iptables kill-switch. All the service processes that
touch your data (**rtorrent** and **flood**) drop privileges to a dedicated
`rtorrent` user, which is created as **uid/gid 1000:1000 by default**. On
every boot `prepare-config.sh` `chown`s `/config` and `/output` to that user,
so downloads land on `/output` owned by uid 1000 (your typical host user).

If your host user is a different uid/gid, set the **`PUID`/`PGID` build args**:

```bash
docker build --build-arg PUID=1000 --build-arg PGID=1000 -t rtorrent-flood-openvpn .
```

> Do not run the whole container with `--user` — the kill-switch/OpenVPN
> still need root (PID 1). Only the file-touching services drop to
> `rtorrent`.

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

## Migrating from the old CentOS image (flood v1)

If you are already running the old image (`h1f0x/rtorrent-flood-openvpn`,
CentOS + flood v1) and want to move to this fork's flood v4 image
(`ghcr.io/poespas/rtorrent-flood-openvpn`), you can update **in place** - the
mounted `/config` and `/output` carry over. Only the rtorrent config needs
manual changes.

1. **Back up** `/config` (especially `rtorrent/rtorrent.rc`) and take note of
   how the container is started (ports, volumes, networks, env).
2. **Switch the image and recreate the container.** Docker cannot swap the
   image on a running container, so recreate it with the same mounts and
   flags. The new image needs `--cap-add=NET_ADMIN` and `/dev/net/tun` (or
   `--privileged`):
   ```bash
   # old:  image: h1f0x/rtorrent-flood-openvpn
   docker compose up -d
   ```
   ```yaml
   # docker-compose.yml (excerpt)
   services:
     torrent:
       image: ghcr.io/poespas/rtorrent-flood-openvpn
       privileged: true
       volumes:
         - /etc/flood:/config
         - /mnt/disk0:/output
       environment:
         - VIRTUAL_HOST=dl.example.com   # optional: for an nginx-proxy in front
   networks:
     nginx-proxy:
       external: true                   # optional: join your reverse proxy's network
   ```
   `vpn/client.conf`, `vpn/vpn.auth` and the rtorrent `session/`, `watch/`
   and `/output` trees are reused untouched (first-boot only fills in what is
   missing).
3. **Migrate `rtorrent/rtorrent.rc`.** rtorrent 0.10 removed/renamed a few
   commands that the old config uses, so the old file will not start
   (`rtorrent` fails to parse, the supervisor logs "rtorrent failed to
   start"). Either replace it with the new default
   (`/config/rtorrent/rtorrent.rc` is not overwritten - copy it from the
   image with `docker cp <name>:/defaults/config/rtorrent/rtorrent.rc .` and
   re-apply your tweaks), or patch these specific lines:

   - Remove `peer_exchange = yes` and `use_udp_trackers = yes`
     (removed in rtorrent 0.10; PEX and UDP trackers are enabled by default).
   - Rename the legacy getters:
     `d.get_custom1` → `d.custom1` and `d.get_base_path` → `d.base_path`.
   - Replace the inline move-on-finished event with the new helper-script
     version:
     ```
     method.insert = d.get_finished_dir,simple,\
             "if=(d.custom1),\
             (cat, /output/complete/, (d.custom1), /),\
             (cat, /output/complete/unsorted/)"
     method.insert = d.move_complete,simple,"execute=/usr/local/bin/move-complete.sh,$d.base_path=,$d.get_finished_dir="
     method.set_key = event.download.finished,move_complete,"d.stop=;d.move_complete=;d.start=;d.hash"
     ```

   > Why: the old event chained several `execute=mkdir/cp` calls and used
   > `d.get_base_path`/`d.get_custom1`. rtorrent 0.10 renamed those getters
   > and only reliably runs the first `execute` in a multi-command event, so
   > the copy is wrapped in `/usr/local/bin/move-complete.sh`.

4. **Expect a one-time re-check.** On the first start, rtorrent 0.10
   re-verifies the hashes of your existing data (old fast-resume data is not
   trusted across the version jump). During this rtorrent does not answer
   SCGI, so the Flood UI may sit on its boot/loading screen (e.g. stuck on
   "Data Transfer History") until the re-check finishes - it can take tens of
   minutes for large libraries. This happens only once; later restarts are
   fast.
5. **Flood v1 UI state does not migrate.** Flood v4 uses a different database
   and runs with `--auth none` (no `Torrent : Torrent` login), so old flood
   history, users and settings do not carry over. Torrents themselves are
   unaffected (they live in the rtorrent session).

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
`workflow_dispatch`) to GHCR, tagged by flood version:

- `ghcr.io/poespas/rtorrent-flood-openvpn:latest`
- `ghcr.io/poespas/rtorrent-flood-openvpn:<flood-version>` (e.g. `4.16.1`)

No GitHub Releases or git tags are created.

## License

GPL v3.0, see [LICENSE](LICENSE).
