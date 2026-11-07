# Fast WebVNC

**View your Raspberry Pi's desktop from any web browser — no client software, just HTTPS and a password.**

Fast WebVNC is a single-file Bash installer for Debian-based Raspberry Pi systems. It takes the VNC server already on your Pi and puts it behind [noVNC](https://novnc.com/) (VNC in the browser), served by Nginx with HTTPS and password protection. After installing, you open `https://your-pi/vnc.html`, log in, and see your desktop.

## How it works

```
Browser ──HTTPS + Basic Auth──> Nginx ──> websockify/noVNC ──> VNC server (localhost only)
```

- **Nginx** terminates HTTPS, asks for a username/password, rate-limits login attempts, and proxies WebSocket traffic.
- **websockify** bridges browser WebSockets to the VNC protocol and serves the noVNC web pages.
- **Your VNC server** (WayVNC or RealVNC on Raspberry Pi OS) stays bound to `127.0.0.1`, so it is never exposed to the network directly.

If no VNC server is reachable on `127.0.0.1:5900`, the installer enables Raspberry Pi VNC for you through `raspi-config` and configures it for loopback-only access. VNC-side authentication and encryption are turned off for noVNC compatibility — remote access stays protected because the listener never leaves the machine and all network access goes through authenticated HTTPS. (Local processes on the Pi can reach the VNC port directly, as is normal for local sessions.) Pass `--no-auto-vnc` if you would rather manage the VNC backend yourself.

## Requirements

- A Debian-based system with `apt` and `systemd` (Raspberry Pi OS, Debian, Ubuntu).
- Root access (`sudo`).
- A VNC server on localhost, or a Raspberry Pi where the installer can enable one.

## Quick start

Download `install.sh` (or clone this repo) and run:

```bash
sudo ./install.sh install
```

The installer walks you through the questions (username, password, hostname, certificate type) with sensible defaults. When it finishes, it prints the URL to open in your browser.

For scripted or unattended installs, pass everything up front:

```bash
sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --non-interactive
```

## Wayland desktops

Log into the desktop, then run the installer with `sudo` from that user's
terminal. On labwc (including Raspberry Pi OS) and Sway, the installer can
install WayVNC and connect it to the user's running Wayland display. Existing
Raspberry Pi WayVNC system services retain their normal startup path.
The managed backend listens only on `127.0.0.1` and uses HTTPS authentication.
Use `--no-auto-vnc` to keep managing your own backend.

Automatic setup requires exactly one Wayland socket for the invoking user
(or exactly one desktop when running directly as root). The desktop session
must stay logged in for screen sharing; this does not create a desktop or
share the login screen. Re-run installation if the user's display socket changes.
For compatibility, the managed WayVNC unit uses the legacy name
`fast-webvnc-x11vnc.service`; inspect it with
`sudo journalctl -u fast-webvnc-x11vnc.service`.

WayVNC supports wlroots compositors, including labwc and Sway. It does not
support GNOME or KDE. Those desktops need a separately configured VNC server
on loopback; their RDP sharing endpoints cannot be connected to noVNC.
See the [WayVNC documentation](https://github.com/any1/wayvnc#introduction).

## Certificate options

The default is a **self-signed certificate**, which works everywhere but makes browsers show a warning on first visit. For a trusted certificate, you have three options:

**Let's Encrypt via DNS (recommended for public endpoints).** Works behind NAT and never opens port 80:

```bash
sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --cert-mode letsencrypt-dns \
  --hostname vnc.example.com --email admin@example.com \
  --dns-auth-hook /usr/local/bin/certbot-dns-auth \
  --dns-cleanup-hook /usr/local/bin/certbot-dns-cleanup \
  --non-interactive
```

**Let's Encrypt via HTTP.** Simpler, but requires public DNS pointing at your machine and TCP port 80 reachable from the internet:

```bash
sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --cert-mode letsencrypt \
  --hostname vnc.example.com --email admin@example.com --non-interactive
```

**Bring your own certificate:**

```bash
sudo ./install.sh install --cert-mode provided \
  --cert-file /etc/ssl/certs/vnc.example.com.pem \
  --key-file /etc/ssl/private/vnc.example.com.key
```

### Cloudflare DNS-01, fully automated

If your DNS is on Cloudflare, you don't need to write hook scripts — pass `--cf-api-token` and `--cf-zone-id` (or their env var equivalents) and the installer generates the hooks in `/etc/fast-webvnc/` and removes them on uninstall:

```bash
sudo FAST_WEBVNC_CF_API_TOKEN='your-token' FAST_WEBVNC_CF_ZONE_ID='your-zone-id' \
  FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --non-interactive \
  --cert-mode letsencrypt-dns \
  --hostname vnc.example.com \
  --email admin@example.com
```

To get the token: Cloudflare dashboard → My Profile → API Tokens → Create Token, using the **Edit zone DNS** template scoped to your zone. The Zone ID is on the zone's Overview page.

For other DNS providers, write a pair of hook scripts and pass them via `--dns-auth-hook` / `--dns-cleanup-hook` instead.

## Everyday commands

```bash
./install.sh help                             # full option reference
sudo ./install.sh verify                      # health-check the whole stack
./install.sh status                           # show installed state and endpoint URL
sudo ./install.sh add-user --user alice       # add another login
sudo ./install.sh set-password --user alice   # change a password
sudo ./install.sh remove-user --user alice    # remove a login
./install.sh logs                             # recent service and Nginx logs
sudo ./install.sh rollback                    # restore files from the latest backup
sudo ./install.sh uninstall                   # remove everything the installer added
```

Re-running `install` updates the managed service and site while preserving your existing users. Every install backs up the files it touches to `/var/backups/fast-webvnc/` first, and a failed install restores them automatically.

## Security notes

- Prefer DNS-01 certificates for public endpoints: no open port 80, and it works behind NAT when your DNS provider has an API.
- The generated Nginx site enables TLS hardening, Basic Auth rate limiting, security headers, and WebSocket proxying only on `/websockify`. The systemd unit runs as a dedicated `fast-webvnc` system user with systemd sandboxing.
- When the installer manages Raspberry Pi VNC, the VNC server is bound to loopback and remote authentication happens at the HTTPS layer. The VNC port should never be reachable from the LAN.
- Passwords must be at least 12 characters. Prefer the interactive prompt or `FAST_WEBVNC_PASSWORD`; a `--password` argument can be visible in process listings while the installer runs.
- If the installer created the `fast-webvnc` system user, `uninstall` removes it. If you pass your own `--service-user`, the installer leaves that account alone.
- The bundled noVNC assets currently require a relaxed CSP with `unsafe-inline` and `unsafe-eval`; the generated site keeps that policy scoped to the authenticated noVNC origin.
- Nginx rate limiting is enabled, but for high-risk public deployments consider adding a VPN, a Zero Trust proxy, or fail2ban-style log-based blocking in front.

## Troubleshooting

**"No VNC server is reachable"** — automatic Raspberry Pi VNC setup was unavailable or failed. Enable WayVNC or RealVNC manually and make sure it listens on `127.0.0.1`.

**`nginx -t` fails** — look for port or `server_name` conflicts in `/etc/nginx/sites-enabled/fast-webvnc` and any other enabled sites.

**Certbot HTTP-01 failures** — usually mean public DNS does not reach this host on TCP port 80. Switch to `--cert-mode letsencrypt-dns` if you can.

**Not sure what's broken?** `sudo ./install.sh verify` checks the systemd service, Nginx config, TLS files, the local noVNC page, the WebSocket upgrade, VNC backend reachability, and the HTTPS endpoint, and reports each result.

## Contributing

Contributions are welcome! The whole project is plain Bash, and everything you need is an ordinary script in this repo — see [CONTRIBUTING.md](CONTRIBUTING.md) for how to build, test, and submit changes.

The short version: development happens in the modules under [src/](src/), and [scripts/build-release.sh](scripts/build-release.sh) concatenates them into the single-file `install.sh` release artifact.

## License

[MIT](LICENSE)
