#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/install.sh"
MODE="dry-run"
YES=0
FORCE_EXISTING=0
KEEP_LOGS=0
HOSTNAME_VALUE="testpi.local"
PUBLIC_HOSTNAME="vnc-test.example.com"
EMAIL="admin@example.com"
VNC_PORT=15900
NOVNC_PORT=16080
HTTPS_PORT=16443

TOTAL=0
PASSED=0
FAILED=0
MOCK_VNC_PID=""
LIVE_INSTALLED=0

RESULT_NAMES=()
RESULT_STATUS=()
RESULT_LOGS=()

usage() {
  cat >&2 <<'EOF'
Usage: scripts/exercise-system.sh [options]

Runs a simple pass/fail harness for fast-webvnc.

Default mode is non-destructive: it exercises help, validation, dry-run install
variants, dry-run actions, and preflight failure cases.

Live mode is for disposable test systems. It installs packages, writes normal
fast-webvnc system paths, starts/stops services, manages users, uninstalls,
rolls back, and uninstalls again.

Options:
  --live                    Run destructive live system tests.
  --yes                     Required with --live.
  --force-existing          Allow --live even if fast-webvnc state already exists.
  --installer PATH          Installer to exercise. Default: ./install.sh.
  --hostname NAME           Local hostname for self-signed tests.
  --public-hostname NAME    Public-looking hostname for Let's Encrypt dry-runs.
  --email EMAIL             Email used in Let's Encrypt dry-runs.
  --vnc-port PORT           Mock VNC backend port. Default: 15900.
  --novnc-port PORT         noVNC port for tests. Default: 16080.
  --https-port PORT         HTTPS port for tests. Default: 16443.
  --keep-logs               Keep per-case logs after exit.
  -h, --help                Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --live)
      MODE="live"
      shift
      ;;
    --yes)
      YES=1
      shift
      ;;
    --force-existing)
      FORCE_EXISTING=1
      shift
      ;;
    --installer)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      INSTALLER="$2"
      shift 2
      ;;
    --installer=*)
      INSTALLER="${1#*=}"
      shift
      ;;
    --hostname)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      HOSTNAME_VALUE="$2"
      shift 2
      ;;
    --hostname=*)
      HOSTNAME_VALUE="${1#*=}"
      shift
      ;;
    --public-hostname)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      PUBLIC_HOSTNAME="$2"
      shift 2
      ;;
    --public-hostname=*)
      PUBLIC_HOSTNAME="${1#*=}"
      shift
      ;;
    --email)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      EMAIL="$2"
      shift 2
      ;;
    --email=*)
      EMAIL="${1#*=}"
      shift
      ;;
    --vnc-port)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      VNC_PORT="$2"
      shift 2
      ;;
    --vnc-port=*)
      VNC_PORT="${1#*=}"
      shift
      ;;
    --novnc-port)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      NOVNC_PORT="$2"
      shift 2
      ;;
    --novnc-port=*)
      NOVNC_PORT="${1#*=}"
      shift
      ;;
    --https-port)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      HTTPS_PORT="$2"
      shift 2
      ;;
    --https-port=*)
      HTTPS_PORT="${1#*=}"
      shift
      ;;
    --keep-logs)
      KEEP_LOGS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

TMP_DIR="$(mktemp -d)"
LOG_DIR="${TMP_DIR}/logs"
mkdir -p "$LOG_DIR"

cleanup() {
  if [[ -n "$MOCK_VNC_PID" ]]; then
    kill "$MOCK_VNC_PID" >/dev/null 2>&1 || true
    wait "$MOCK_VNC_PID" 2>/dev/null || true
  fi

  if (( KEEP_LOGS || FAILED > 0 )); then
    printf 'Logs kept in %s\n' "$LOG_DIR"
  else
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

sanitize_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9._-]/_}"
  printf '%s' "$value"
}

record_result() {
  local name="$1"
  local status="$2"
  local log_file="$3"

  RESULT_NAMES+=("$name")
  RESULT_STATUS+=("$status")
  RESULT_LOGS+=("$log_file")
}

run_case() {
  local expected="$1"
  local name="$2"
  local log_file
  local status
  shift 2

  TOTAL=$((TOTAL + 1))
  log_file="${LOG_DIR}/$(printf '%02d' "$TOTAL")-$(sanitize_name "$name").log"

  printf '[%02d] %s ... ' "$TOTAL" "$name"
  set +e
  "$@" >"$log_file" 2>&1
  status=$?
  set -e

  if [[ "$status" == "$expected" ]]; then
    PASSED=$((PASSED + 1))
    record_result "$name" "PASS" "$log_file"
    printf 'PASS\n'
  else
    FAILED=$((FAILED + 1))
    record_result "$name" "FAIL expected ${expected}, got ${status}" "$log_file"
    printf 'FAIL expected %s, got %s\n' "$expected" "$status"
  fi
}

base_env() {
  env \
    FAST_WEBVNC_USER=testadmin \
    FAST_WEBVNC_PASSWORD=test-password-123 \
    "$@"
}

make_dns_hook() {
  local path="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'exit 0\n'
  } > "$path"
  chmod 0755 "$path"
}

make_provided_cert_placeholders() {
  PROVIDED_CERT="${TMP_DIR}/provided.crt"
  PROVIDED_KEY="${TMP_DIR}/provided.key"
  : > "$PROVIDED_CERT"
  : > "$PROVIDED_KEY"
  chmod 0644 "$PROVIDED_KEY"
}

make_mock_ss_conflict() {
  local bin_dir="${TMP_DIR}/mock-bin"
  mkdir -p "$bin_dir"
  cat > "${bin_dir}/ss" <<EOF
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:6080 0.0.0.0:* users:(("conflict",pid=123,fd=3))'
EOF
  chmod 0755 "${bin_dir}/ss"
  MOCK_SS_PATH="${bin_dir}:${PATH}"
}

start_mock_vnc() {
  local server_py="${TMP_DIR}/mock-vnc.py"

  cat > "$server_py" <<'PY'
import socket
import sys
import threading

host = "127.0.0.1"
port = int(sys.argv[1])

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((host, port))
sock.listen(20)

def handle(conn):
    try:
        conn.sendall(b"RFB 003.008\n")
    finally:
        conn.close()

while True:
    conn, _ = sock.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

  python3 "$server_py" "$VNC_PORT" &
  MOCK_VNC_PID="$!"
  sleep 1
}

run_dry_run_suite() {
  local auth_hook="${TMP_DIR}/dns-auth"
  local cleanup_hook="${TMP_DIR}/dns-cleanup"

  make_dns_hook "$auth_hook"
  make_dns_hook "$cleanup_hook"
  make_provided_cert_placeholders
  make_mock_ss_conflict

  run_case 0 "help" "$INSTALLER" help
  run_case 0 "status" "$INSTALLER" status
  run_case 0 "logs dry-run" "$INSTALLER" logs --dry-run
  run_case 0 "verify dry-run" "$INSTALLER" verify --dry-run
  run_case 0 "uninstall dry-run force" "$INSTALLER" uninstall --dry-run --force
  run_case 67 "rollback without backup" "$INSTALLER" rollback --dry-run

  run_case 0 "install self-signed dry-run" \
    base_env "$INSTALLER" install --dry-run --non-interactive \
      --hostname "$HOSTNAME_VALUE" --vnc-port "$VNC_PORT" \
      --novnc-port "$NOVNC_PORT" --https-port "$HTTPS_PORT"

  run_case 0 "install provided cert dry-run" \
    base_env "$INSTALLER" install --dry-run --non-interactive \
      --cert-mode provided --cert-file "$PROVIDED_CERT" --key-file "$PROVIDED_KEY" \
      --hostname "$HOSTNAME_VALUE" --vnc-port "$VNC_PORT" \
      --novnc-port "$((NOVNC_PORT + 1))" --https-port "$((HTTPS_PORT + 1))"

  run_case 0 "install letsencrypt staging dry-run" \
    base_env "$INSTALLER" install --dry-run --non-interactive \
      --cert-mode letsencrypt --cert-staging \
      --hostname "$PUBLIC_HOSTNAME" --email "$EMAIL" \
      --vnc-port "$VNC_PORT" --novnc-port "$((NOVNC_PORT + 2))" \
      --https-port "$((HTTPS_PORT + 2))"

  run_case 0 "install letsencrypt dns hooks dry-run" \
    base_env "$INSTALLER" install --dry-run --non-interactive \
      --cert-mode letsencrypt-dns --hostname "$PUBLIC_HOSTNAME" --email "$EMAIL" \
      --dns-auth-hook "$auth_hook" --dns-cleanup-hook "$cleanup_hook" \
      --vnc-port "$VNC_PORT" --novnc-port "$((NOVNC_PORT + 3))" \
      --https-port "$((HTTPS_PORT + 3))"

  run_case 0 "install letsencrypt dns cloudflare dry-run" \
    base_env "$INSTALLER" install --dry-run --non-interactive \
      --cert-mode letsencrypt-dns --hostname "$PUBLIC_HOSTNAME" --email "$EMAIL" \
      --cf-api-token test-token --cf-zone-id test-zone \
      --vnc-port "$VNC_PORT" --novnc-port "$((NOVNC_PORT + 4))" \
      --https-port "$((HTTPS_PORT + 4))"

  run_case 0 "add-user dry-run" \
    env FAST_WEBVNC_PASSWORD=test-password-123 "$INSTALLER" add-user --dry-run --non-interactive --user alice

  run_case 0 "set-password dry-run" \
    env FAST_WEBVNC_PASSWORD=test-password-456 "$INSTALLER" set-password --dry-run --non-interactive --user alice

  run_case 64 "invalid hostname rejected" \
    base_env "$INSTALLER" install --dry-run --non-interactive --hostname "bad;name"

  run_case 64 "invalid auto-vnc env rejected" \
    env FAST_WEBVNC_USER=testadmin FAST_WEBVNC_PASSWORD=test-password-123 FAST_WEBVNC_AUTO_VNC_BACKEND=maybe \
      "$INSTALLER" install --dry-run --non-interactive --hostname "$HOSTNAME_VALUE"

  run_case 65 "novnc port conflict preflight" \
    env PATH="$MOCK_SS_PATH" FAST_WEBVNC_USER=testadmin FAST_WEBVNC_PASSWORD=test-password-123 \
      "$INSTALLER" install --dry-run --non-interactive --hostname "$HOSTNAME_VALUE" --novnc-port 6080
}

require_live_prerequisites() {
  if (( EUID != 0 )); then
    printf 'ERROR: --live must be run as root on a disposable test system.\n' >&2
    exit 64
  fi

  if (( ! YES )); then
    printf 'ERROR: --live requires --yes because it installs packages and modifies system paths.\n' >&2
    exit 64
  fi

  if [[ -f /var/lib/fast-webvnc/state.env && "$FORCE_EXISTING" != "1" ]]; then
    printf 'ERROR: existing fast-webvnc state found. Refusing live tests without --force-existing.\n' >&2
    exit 65
  fi

  command -v python3 >/dev/null 2>&1 || {
    printf 'ERROR: python3 is required for the mock VNC backend.\n' >&2
    exit 65
  }
}

run_live_suite() {
  require_live_prerequisites
  start_mock_vnc

  run_case 0 "live install" \
    base_env "$INSTALLER" install --non-interactive --force --no-auto-vnc \
      --hostname "$HOSTNAME_VALUE" --vnc-port "$VNC_PORT" \
      --novnc-port "$NOVNC_PORT" --https-port "$HTTPS_PORT"
  if [[ "${RESULT_STATUS[$((${#RESULT_STATUS[@]} - 1))]}" == "PASS" ]]; then
    LIVE_INSTALLED=1
  fi

  run_case 0 "live verify" "$INSTALLER" verify
  run_case 0 "live status" "$INSTALLER" status
  run_case 0 "live logs" "$INSTALLER" logs
  run_case 0 "live add-user" env FAST_WEBVNC_PASSWORD=test-password-456 "$INSTALLER" add-user --non-interactive --user alice
  run_case 0 "live set-password" env FAST_WEBVNC_PASSWORD=test-password-789 "$INSTALLER" set-password --non-interactive --user alice
  run_case 0 "live remove-user" "$INSTALLER" remove-user --user alice
  run_case 0 "live uninstall" "$INSTALLER" uninstall
  LIVE_INSTALLED=0
  run_case 0 "live rollback after uninstall" "$INSTALLER" rollback
  LIVE_INSTALLED=1
  run_case 0 "live verify after rollback" "$INSTALLER" verify
  run_case 0 "live final uninstall" "$INSTALLER" uninstall --force
  LIVE_INSTALLED=0
}

print_summary() {
  local i

  printf '\nSummary\n'
  printf '  Mode:   %s\n' "$MODE"
  printf '  Total:  %d\n' "$TOTAL"
  printf '  Passed: %d\n' "$PASSED"
  printf '  Failed: %d\n' "$FAILED"

  printf '\nResults\n'
  for i in "${!RESULT_NAMES[@]}"; do
    printf '  %-45s %s\n' "${RESULT_NAMES[$i]}" "${RESULT_STATUS[$i]}"
    if [[ "${RESULT_STATUS[$i]}" != "PASS" ]]; then
      printf '    log: %s\n' "${RESULT_LOGS[$i]}"
    fi
  done

  if (( KEEP_LOGS )); then
    printf '\nLogs: %s\n' "$LOG_DIR"
  elif (( FAILED > 0 )); then
    printf '\nLogs: %s\n' "$LOG_DIR"
  fi
}

if [[ ! -x "$INSTALLER" ]]; then
  printf 'ERROR: installer is not executable: %s\n' "$INSTALLER" >&2
  exit 64
fi

case "$MODE" in
  dry-run)
    run_dry_run_suite
    ;;
  live)
    run_live_suite
    ;;
esac

print_summary

if (( FAILED > 0 )); then
  if (( LIVE_INSTALLED )); then
    printf '\nWARNING: live test stopped after an install; run %s uninstall --force to clean up.\n' "$INSTALLER" >&2
  fi
  exit 1
fi
