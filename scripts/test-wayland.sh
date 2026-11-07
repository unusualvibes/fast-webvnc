#!/usr/bin/env bash
# Isolated backend lifecycle tests; no system services or packages are changed.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=src/50-network-vnc.sh
source "${ROOT_DIR}/src/50-network-vnc.sh"
# Ordinary install enables automatic migration without requiring a flag.
# shellcheck disable=SC2016
env -u FAST_WEBVNC_AUTO_VNC_BACKEND bash -c '
  source "$1"
  [[ "$AUTO_VNC_BACKEND" == 1 ]]
' _ "${ROOT_DIR}/src/00-bootstrap.sh"
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
  WAYLAND_BACKEND_DISPLAY="wayland-1"
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
# Reproduce the upgrade: a healthy RFB banner from RealVNC must not bypass
# migration when the active desktop is Wayland.
(
  # shellcheck source=src/50-network-vnc.sh
  source "${ROOT_DIR}/src/50-network-vnc.sh"
  AUTO_VNC_BACKEND=1
  EXIT_PRECHECK=65
  is_local_host() { [[ "$1" == 127.0.0.1 ]]; }
  find_wayland_session() { return 0; }
  list_listener_lines_on_port() {
    if [[ ! -f "${TEST_DIR}/x11-stopped" ]]; then
      printf '%s\n' 'LISTEN 0 5 127.0.0.1:15900 0.0.0.0:* users:(("vncserver-x11-co",pid=123,fd=9))'
    fi
  }
  systemctl() {
    printf '%s\n' "$*" >> "${TEST_DIR}/migration-calls"
    case "$*" in
      'is-active --quiet vncserver-x11-serviced.service') return 0 ;;
      'stop vncserver-x11-serviced.service') touch "${TEST_DIR}/x11-stopped" ;;
      'show wayvnc.service --property=LoadState --value') printf 'loaded\n' ;;
      'show '* ) printf 'not-found\n' ;;
      'is-active '* ) return 1 ;;
    esac
  }
  die() { printf '%s\n' "$2" >&2; exit "$1"; }
  # If migration regresses to the RFB-only check, this fails the test.
  vnc_protocol_responds() { return 0; }
  require_vnc_loopback_only() { :; }
  start_hardened_raspberry_pi_vnc() { touch "${TEST_DIR}/wayvnc-started"; }
  ensure_vnc_backend
  test -f "${TEST_DIR}/wayvnc-started"
  grep -q '^disable vncserver-x11-serviced.service$' "${TEST_DIR}/migration-calls"

  # --no-auto-vnc must reject the incompatible server without stopping it.
  rm "${TEST_DIR}/x11-stopped"
  AUTO_VNC_BACKEND=0
  result=0
  (ensure_vnc_backend) > /dev/null 2>&1 || result=$?
  test "$result" = 65
  test ! -f "${TEST_DIR}/x11-stopped"

  # If WayVNC fails, restore RealVNC and report failure instead of accepting
  # its error desktop as a successful migration.
  AUTO_VNC_BACKEND=1
  start_hardened_raspberry_pi_vnc() { return 1; }
  try_start_wayland_backend() { return 1; }
  : > "${TEST_DIR}/migration-calls"
  if migrate_x11_backend_to_wayland; then exit 1; fi
  grep -q '^start vncserver-x11-serviced.service$' "${TEST_DIR}/migration-calls"
  if grep -q '^disable ' "${TEST_DIR}/migration-calls"; then exit 1; fi

  # A missing systemd unit must not be mistaken for an installed service.
  if systemd_unit_exists missing.service; then exit 1; fi

  # On Wayland, the Pi startup path must never enable or start RealVNC.
  systemd_unit_exists() { return 0; }
  : > "${TEST_DIR}/migration-calls"
  restart_pi_vnc_units
  grep -q '^restart wayvnc.service$' "${TEST_DIR}/migration-calls"
  if grep -q 'vncserver-x11' "${TEST_DIR}/migration-calls"; then exit 1; fi
)
printf 'Wayland backend tests passed\n'
