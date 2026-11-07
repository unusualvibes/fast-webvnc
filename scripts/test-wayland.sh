#!/usr/bin/env bash
# Isolated backend lifecycle tests; no system services or packages are changed.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=src/50-network-vnc.sh
source "${ROOT_DIR}/src/50-network-vnc.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
VNC_BACKEND_SERVICE_FILE="${TEST_DIR}/backend.service"
VNC_BACKEND_SERVICE_NAME=fast-webvnc-x11vnc.service
VNC_PORT=15900
VNC_HOST=127.0.0.1
VNC_BACKEND_MANAGED=0
DRY_RUN=0
info() { :; }
warn() { :; }
find_wayland_session() {
  WAYLAND_BACKEND_UID=1000
  WAYLAND_BACKEND_DISPLAY=wayland-1
}
systemd_unit_exists() { return 1; }
command() {
  if [[ "$*" == '-v wayvnc' ]]; then
    printf '/usr/bin/wayvnc\n'
  else
    builtin command "$@"
  fi
}
systemctl() { printf '%s\n' "$*" >> "${TEST_DIR}/calls"; }
wait_for_vnc_backend() { return 0; }
vnc_listeners_loopback_only() { return 0; }

try_start_wayland_backend
test "$VNC_BACKEND_MANAGED" = 1
grep -q '^User=1000$' "$VNC_BACKEND_SERVICE_FILE"
grep -q '^Environment=XDG_RUNTIME_DIR=/run/user/1000$' "$VNC_BACKEND_SERVICE_FILE"
grep -q '^Environment=WAYLAND_DISPLAY=wayland-1$' "$VNC_BACKEND_SERVICE_FILE"
grep -q '^ExecStart=/usr/bin/wayvnc --config=/dev/null 127.0.0.1 15900$' "$VNC_BACKEND_SERVICE_FILE"
grep -q '^enable fast-webvnc-x11vnc.service$' "${TEST_DIR}/calls"

# Startup failure must stop retries and disable the failed backend.
wait_for_vnc_backend() { return 1; }
if try_start_wayland_backend; then exit 1; fi
grep -q '^stop fast-webvnc-x11vnc.service$' "${TEST_DIR}/calls"
grep -q '^disable fast-webvnc-x11vnc.service$' "${TEST_DIR}/calls"
wait_for_vnc_backend() { return 0; }

# Never replace an administrator's unit.
printf 'unmanaged\n' > "$VNC_BACKEND_SERVICE_FILE"
if try_start_wayland_backend; then exit 1; fi
test "$(cat "$VNC_BACKEND_SERVICE_FILE")" = unmanaged

# Distro-managed WayVNC takes precedence.
systemd_unit_exists() { return 0; }
if try_start_wayland_backend; then exit 1; fi

# A failed socket/session discovery must not start services.
systemd_unit_exists() { return 1; }
find_wayland_session() { return 1; }
if try_start_wayland_backend; then exit 1; fi
printf 'Wayland backend tests passed\n'
