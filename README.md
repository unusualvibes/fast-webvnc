# Fast WebVNC

Fast WebVNC is a single-file Bash installer for Debian-based Raspberry Pi systems. It exposes a local VNC server through noVNC behind Nginx HTTPS and Basic Auth.

The release installer is [install.sh](install.sh). Development happens in sourced modules under [src/](src/), and [scripts/build-release.sh](scripts/build-release.sh) concatenates those modules into the single-file release artifact.

If no VNC backend is reachable on `127.0.0.1:5900`, the installer enables and hardens Raspberry Pi VNC through `raspi-config` when available. It configures WayVNC or RealVNC for loopback-only access, disables VNC-side network authentication/encryption for noVNC compatibility, then exposes access only through authenticated HTTPS/noVNC. Use `--no-auto-vnc` to disable automatic backend setup. Uninstall restores the Raspberry Pi VNC config files captured before install; if the installer enabled Pi VNC, uninstall stops and disables it.

## Quick Start

Interactive install:

```bash
sudo ./install.sh install
```

Unattended self-signed install:

```bash
sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --non-interactive
```

Let's Encrypt with DNS-01 hooks:

```bash
sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --cert-mode letsencrypt-dns \
  --hostname vnc.example.com --email admin@example.com \
  --dns-auth-hook /usr/local/bin/certbot-dns-auth \
  --dns-cleanup-hook /usr/local/bin/certbot-dns-cleanup \
  --non-interactive
```

Bring your own certificate:

```bash
sudo ./install.sh install --cert-mode provided \
  --cert-file /etc/ssl/certs/vnc.example.com.pem \
  --key-file /etc/ssl/private/vnc.example.com.key
```

## Cloudflare DNS-01 (Unattended)

This is the recommended path for public endpoints — it avoids opening TCP port 80 and works behind NAT.

Pass `--cf-api-token` and `--cf-zone-id` (or their env var equivalents); the installer writes the hook scripts to `/etc/fast-webvnc/` and removes them on uninstall.

```bash
sudo FAST_WEBVNC_CF_API_TOKEN='your-token' FAST_WEBVNC_CF_ZONE_ID='your-zone-id' \
  FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
  ./install.sh install --non-interactive \
  --cert-mode letsencrypt-dns \
  --hostname vnc.example.com \
  --email admin@example.com
```

Get `CF_API_TOKEN` from the Cloudflare dashboard → My Profile → API Tokens → Create Token (use the **Edit zone DNS** template, scoped to the target zone). Get `CF_ZONE_ID` from the zone's Overview page.

For other DNS providers, write your own hook scripts and pass them via `--dns-auth-hook` / `--dns-cleanup-hook` instead.

## Actions

```bash
./install.sh help
sudo ./install.sh verify
./install.sh status
sudo ./install.sh add-user --user alice
sudo ./install.sh set-password --user alice
sudo ./install.sh remove-user --user alice
./install.sh logs
sudo ./install.sh rollback
sudo ./install.sh uninstall
```

## Security Notes

Use DNS-01 for public WebVNC endpoints when possible. It avoids exposing TCP port 80 and works for hosts behind NAT or private firewalls when your DNS provider has an automation API.

The generated Nginx site enables TLS/session hardening, Basic Auth rate limiting, security headers, and WebSocket proxying only on `/websockify`. The systemd unit runs as a dedicated `fast-webvnc` system user by default and applies systemd sandboxing.

When the installer manages Raspberry Pi VNC, it binds the VNC server to loopback and relies on the HTTPS Basic Auth layer for remote authentication. The VNC port should not be reachable from the LAN.

Basic Auth passwords must be at least 12 characters. Prefer the interactive prompt or `FAST_WEBVNC_PASSWORD`; `--password` can be visible in process listings while the installer is running.

If the installer creates the dedicated `fast-webvnc` system user, `uninstall` removes that user after stopping the service. If you pass `--service-user`, the installer treats that account as user-managed and does not remove it.

The bundled noVNC assets currently require a relaxed CSP with `unsafe-inline` and `unsafe-eval`. The generated site keeps that policy scoped to the authenticated noVNC origin.

Rate limiting is enabled in Nginx, but high-risk public deployments should still put this behind a VPN, Zero Trust proxy, or fail2ban-equivalent log-based blocking.

## Troubleshooting

`No VNC server is reachable`: automatic Raspberry Pi VNC setup was unavailable or failed. Enable WayVNC/RealVNC manually and bind it to `127.0.0.1`.

`nginx -t` fails: inspect `/etc/nginx/sites-enabled/fast-webvnc` and unrelated enabled sites for port or `server_name` conflicts.

Certbot HTTP-01 failures usually mean public DNS does not reach this host on TCP port 80. Prefer `--cert-mode letsencrypt-dns` with DNS automation when possible.

`verify` checks the systemd service, Nginx config, TLS files, local noVNC `/vnc.html`, WebSocket upgrade, backend VNC reachability, and the HTTPS endpoint.

Re-running `install` updates the managed service/site and preserves existing Basic Auth users. Use `add-user`, `set-password`, and `remove-user` for auth changes.

## Development Checks

Edit the sourced modules in `src/`, then rebuild the release installer:

```bash
scripts/build-release.sh
scripts/build-release.sh --check
```

The release artifact is `install.sh`; it is generated by concatenating the ordered modules listed in [scripts/build-release.sh](scripts/build-release.sh). For local module-based execution, use:

```bash
src/fast-webvnc.sh help
```

```bash
bash -n install.sh
shellcheck --severity=style install.sh
shellcheck -x --source-path=. --severity=style scripts/build-release.sh src/fast-webvnc.sh
python3 -m http.server 15900 --bind 127.0.0.1
FAST_WEBVNC_USER=test FAST_WEBVNC_PASSWORD='test-password' \
  ./install.sh install --dry-run --non-interactive \
  --hostname testpi.local --vnc-port 15900
```
