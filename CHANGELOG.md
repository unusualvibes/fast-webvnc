# Changelog

## Unreleased

## 1.2.0 - 2026-11-07

- Added automatic WayVNC setup for logged-in labwc and Sway desktops.
- Automatically migrate conflicting X11 VNC backends to WayVNC on Wayland.
- Prevent RealVNC from starting alongside WayVNC on Wayland desktops.
- Added Wayland backend lifecycle and migration regression tests.
- Publish tagged builds as GitHub prereleases.

- Rewrote the README and help text for newcomers and added CONTRIBUTING.md.
- Added module header comments and explanatory comments throughout the source.

## 1.1.0 - 2026-05-24

- Added multi-user Basic Auth management actions.
- Hardened generated Nginx and systemd configurations.
- Added DNS-01, provided-certificate, and staging certificate modes.
- Added stronger verification checks and rollback service restart.
- Added CI, README, license, and repository hygiene files.
- Split installer development into sourced modules with a concat-at-release build.
