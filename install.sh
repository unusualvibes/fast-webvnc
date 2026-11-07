#!/usr/bin/env bash
set -Eeuo pipefail

# 00-bootstrap.sh — constants, managed paths, defaults, and global state.
#
# The release install.sh is generated from src/*.sh by scripts/build-release.sh.
# Edit the modules here, then rebuild the single-file installer.

VERSION="1.1.0"

# Exit codes, loosely following BSD sysexits: 64 for bad usage, then one
# distinct code per failure phase so scripts can tell them apart.

EXIT_USAGE=64
EXIT_PRECHECK=65
EXIT_VERIFY=66
EXIT_ROLLBACK=67

# Every file the installer creates or manages lives at one of these paths.
# Keep this list in sync with safe_managed_path() in 60-backup-rollback.sh,
# which allowlists what rollback/uninstall are permitted to delete.
SERVICE_NAME="fast-webvnc.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
VNC_BACKEND_SERVICE_NAME="fast-webvnc-x11vnc.service"
VNC_BACKEND_SERVICE_FILE="/etc/systemd/system/${VNC_BACKEND_SERVICE_NAME}"
NGINX_SITE_NAME="fast-webvnc"
NGINX_SITE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
CONFIG_DIR="/etc/fast-webvnc"
PI_WAYVNC_CONFIG_FILE="/etc/wayvnc/config"
PI_REALVNC_CONFIG_FILE="/root/.vnc/config.d/vncserver-x11"
CF_CREDENTIALS_FILE="${CONFIG_DIR}/cf-credentials"
CF_AUTH_HOOK="${CONFIG_DIR}/cf-dns-auth"
CF_CLEANUP_HOOK="${CONFIG_DIR}/cf-dns-cleanup"
CERT_DIR="${CONFIG_DIR}/certs"
CERT_FILE="${CERT_DIR}/fast-webvnc.crt"
KEY_FILE="${CERT_DIR}/fast-webvnc.key"
AUTH_FILE="${CONFIG_DIR}/htpasswd"
STATE_DIR="/var/lib/fast-webvnc"
STATE_FILE="${STATE_DIR}/state.env"
ACME_WEBROOT="${STATE_DIR}/acme-webroot"
CERTBOT_RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/fast-webvnc-reload-nginx"
BACKUP_ROOT="/var/backups/fast-webvnc"
DEFAULT_SERVICE_USER="fast-webvnc"
MIN_PASSWORD_LENGTH=12

# Runtime flags and derived values, filled in by argument parsing and the
# preflight/runtime-detection steps.
ACTION=""
DRY_RUN=0
FORCE=0
NON_INTERACTIVE=0
VERBOSE=0
HOSTNAME_EXPLICIT=0
SERVICE_USER_EXPLICIT=0
ROLLBACK_IN_PROGRESS=0
INSTALL_STARTED=0
CURRENT_ACTION=""
BACKUP_DIR_CURRENT=""
APT_CMD=""
NOVNC_WEB_ROOT=""
NGINX_SERVER_NAMES=""
SAN_LIST=""
ENDPOINT_URL=""
ACTIVE_CERT_FILE="$CERT_FILE"
ACTIVE_KEY_FILE="$KEY_FILE"
LE_CERT_NAME=""
HTTP_REDIRECT_TARGET=""
PROVIDED_CERT_FILE="${FAST_WEBVNC_CERT_FILE:-}"
PROVIDED_KEY_FILE="${FAST_WEBVNC_KEY_FILE:-}"
CERT_STAGING="${FAST_WEBVNC_CERT_STAGING:-0}"
CERT_STAGING_ENV="${FAST_WEBVNC_CERT_STAGING:-}"
CERT_STAGING_FLAG=0
DNS_AUTH_HOOK="${FAST_WEBVNC_DNS_AUTH_HOOK:-}"
DNS_CLEANUP_HOOK="${FAST_WEBVNC_DNS_CLEANUP_HOOK:-}"
CF_API_TOKEN="${FAST_WEBVNC_CF_API_TOKEN:-}"
CF_ZONE_ID="${FAST_WEBVNC_CF_ZONE_ID:-}"
WEBSOCKIFY_BIN=""
SERVICE_USER_CREATED=0
PASSWORD_FROM_ARG=0
VNC_BACKEND_MANAGED=0
PI_VNC_AUTOMANAGED=0

# User-facing settings. Each one can come from (highest precedence first)
# a command-line flag, a FAST_WEBVNC_* environment variable, or the default.
WEB_USER="${FAST_WEBVNC_USER:-}"
WEB_PASSWORD="${FAST_WEBVNC_PASSWORD:-}"
VNC_HOST="${FAST_WEBVNC_VNC_HOST:-127.0.0.1}"
VNC_PORT="${FAST_WEBVNC_VNC_PORT:-5900}"
AUTO_VNC_BACKEND="${FAST_WEBVNC_AUTO_VNC_BACKEND:-1}"
NOVNC_PORT="${FAST_WEBVNC_NOVNC_PORT:-6080}"
HTTPS_PORT="${FAST_WEBVNC_HTTPS_PORT:-443}"
HOSTNAME_VALUE="${FAST_WEBVNC_HOSTNAME:-}"
SERVICE_USER="${FAST_WEBVNC_SERVICE_USER:-}"
CERT_MODE="${FAST_WEBVNC_CERT_MODE:-self-signed}"
LE_EMAIL="${FAST_WEBVNC_EMAIL:-}"

# Supplying a certificate or key implies --cert-mode provided.
if [[ -n "$PROVIDED_CERT_FILE" || -n "$PROVIDED_KEY_FILE" ]]; then
  CERT_MODE="provided"
fi

if [[ -n "$HOSTNAME_VALUE" ]]; then
  HOSTNAME_EXPLICIT=1
fi

if [[ -n "$SERVICE_USER" ]]; then
  SERVICE_USER_EXPLICIT=1
fi

# ---- src/10-core.sh ----

# 10-core.sh — logging helpers, the dry-run command wrapper, and the error
# trap that rolls back a failed install.

log() {
  printf '%s\n' "$*"
}

info() {
  log "INFO: $*"
}

warn() {
  log "WARN: $*" >&2
}

error() {
  log "ERROR: $*" >&2
}

debug() {
  if (( VERBOSE )); then
    log "DEBUG: $*" >&2
  fi
}

dns01_guidance() {
  cat <<'EOF'
DNS-01 is recommended for WebVNC endpoints because it avoids exposing TCP port 80. Use a Certbot DNS plugin or another ACME client for your DNS provider when DNS automation is available.
EOF
}

die() {
  local status="$1"
  shift
  error "$*"
  exit "$status"
}

# Run a command, or just print it when --dry-run is active. Anything that
# changes system state should go through this wrapper (or check DRY_RUN
# itself) so dry runs stay side-effect free.
run() {
  if (( DRY_RUN )); then
    info "DRY-RUN: $*"
    return 0
  fi

  debug "Running: $*"
  "$@"
}

# ERR trap: if a real install fails partway through, restore the files that
# were backed up at the start of the run so the system is left as we found it.
err_trap() {
  local line="$1"
  local status="$2"

  if (( status == 0 )); then
    return
  fi

  if [[ "$CURRENT_ACTION" == "install" && "$INSTALL_STARTED" == "1" && "$DRY_RUN" == "0" && "$ROLLBACK_IN_PROGRESS" == "0" ]]; then
    warn "Install failed at line ${line}; attempting to restore files touched by this run."
    ROLLBACK_IN_PROGRESS=1
    set +e
    stop_disable_vnc_backend_if_managed
    rollback_backup_dir "$BACKUP_DIR_CURRENT"
    restart_restored_service_if_present
    cleanup_empty_managed_dirs
    set -e
  fi

  exit "$status"
}

trap 'err_trap "$LINENO" "$?"' ERR


# ---- src/20-help-args.sh ----

# 20-help-args.sh — the help text and command-line argument parsing.

show_help() {
  cat <<'EOF'
Fast WebVNC installer

Usage:
  ./install.sh install [options]
  ./install.sh verify [options]
  ./install.sh status [options]
  ./install.sh rollback [options]
  ./install.sh uninstall [options]
  ./install.sh add-user --user NAME [--password VALUE]
  ./install.sh set-password --user NAME [--password VALUE]
  ./install.sh remove-user --user NAME
  ./install.sh logs
  ./install.sh help

Actions:
  install     Configure HTTPS noVNC through Nginx Basic Auth.
  verify      Check systemd, Nginx, TLS/auth files, HTTPS, and VNC backend.
  status      Print installed state and likely endpoint.
  rollback    Restore files from the latest installer backup.
  uninstall   Stop services and remove files managed by this installer.
  add-user    Add or update an HTTPS Basic Auth user without removing others.
  set-password
              Change an HTTPS Basic Auth user's password.
  remove-user Remove an HTTPS Basic Auth user.
  logs        Show recent fast-webvnc and Nginx journal logs.
  help        Show this help.

Install options:
  --user NAME                 HTTPS Basic Auth username.
  --password VALUE            HTTPS Basic Auth password. Prefer the prompt or
                              FAST_WEBVNC_PASSWORD; arguments show up in ps.
  --vnc-host HOST             Existing VNC backend host. Default: 127.0.0.1.
  --vnc-port PORT             Existing VNC backend port. Default: 5900.
  --auto-vnc                  Auto-enable/create a localhost VNC backend (default).
  --no-auto-vnc               Do not auto-enable/create a localhost VNC backend.
  --novnc-port PORT           Local noVNC/websockify port. Default: 6080.
  --https-port PORT           Nginx HTTPS port. Default: 443.
  --hostname NAME             Hostname used for Nginx and TLS certificates.
  --service-user NAME         Local account used to run websockify.
  --cert-mode MODE            self-signed, letsencrypt, letsencrypt-dns, provided.
  --email EMAIL               Let's Encrypt account contact email.
  --cert-file PATH            Certificate path for --cert-mode provided.
  --key-file PATH             Private key path for --cert-mode provided.
  --cert-staging              Use Let's Encrypt staging for test issuance.
  --dns-auth-hook PATH        Certbot DNS-01 manual auth hook.
  --dns-cleanup-hook PATH     Certbot DNS-01 manual cleanup hook.
  --cf-api-token TOKEN        Cloudflare API token (DNS:Edit scope) for DNS-01.
  --cf-zone-id ID             Cloudflare Zone ID for DNS-01.
  --non-interactive           Never prompt; fail if required values are missing.
  --force                     Allow replacing existing fast-webvnc paths.
  --dry-run                   Validate and print changes without writing files.
  --verbose                   Print debug details.
  -h, --help                  Show this help.

Environment:
  FAST_WEBVNC_USER, FAST_WEBVNC_PASSWORD
  FAST_WEBVNC_VNC_HOST, FAST_WEBVNC_VNC_PORT, FAST_WEBVNC_AUTO_VNC_BACKEND
  FAST_WEBVNC_NOVNC_PORT
  FAST_WEBVNC_HTTPS_PORT, FAST_WEBVNC_HOSTNAME
  FAST_WEBVNC_SERVICE_USER, FAST_WEBVNC_CERT_MODE, FAST_WEBVNC_EMAIL
  FAST_WEBVNC_CERT_FILE, FAST_WEBVNC_KEY_FILE, FAST_WEBVNC_CERT_STAGING
  FAST_WEBVNC_DNS_AUTH_HOOK, FAST_WEBVNC_DNS_CLEANUP_HOOK
  FAST_WEBVNC_CF_API_TOKEN, FAST_WEBVNC_CF_ZONE_ID

Examples:
  sudo ./install.sh install
  sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
    ./install.sh install --non-interactive
  sudo ./install.sh install --vnc-port 5901 --https-port 8443
  sudo FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
    ./install.sh install --cert-mode letsencrypt \
    --hostname vnc.example.com --email admin@example.com --non-interactive
  sudo FAST_WEBVNC_CF_API_TOKEN='token' FAST_WEBVNC_CF_ZONE_ID='zone-id' \
    FAST_WEBVNC_USER=admin FAST_WEBVNC_PASSWORD='change-me-now' \
    ./install.sh install --cert-mode letsencrypt-dns \
    --hostname vnc.example.com --email admin@example.com --non-interactive
  sudo ./install.sh add-user --user alice
  sudo ./install.sh set-password --user alice
  sudo ./install.sh remove-user --user alice
  sudo ./install.sh verify
  ./install.sh status
  sudo ./install.sh rollback
  sudo ./install.sh uninstall

Notes:
  If no VNC backend is reachable on 127.0.0.1:5900, the installer enables and
  hardens Raspberry Pi VNC (WayVNC or RealVNC) for loopback-only access, then
  proxies it through authenticated HTTPS/noVNC. VNC-side network
  authentication/encryption is disabled for noVNC compatibility because the
  VNC listener is local-only. Uninstall restores the backed-up Raspberry Pi VNC
  configs and disables Pi VNC if the installer enabled it.
  Basic Auth passwords must be at least 12 characters. Prefer the interactive
  prompt or FAST_WEBVNC_PASSWORD; --password is visible via process listings
  while the installer is running.
  DNS-01 is recommended for WebVNC endpoints because it avoids exposing TCP
  port 80. Use a Certbot DNS plugin or another ACME client for your DNS
  provider when DNS automation is available.
  For letsencrypt-dns with Cloudflare, pass --cf-api-token (DNS:Edit scope) and
  --cf-zone-id; the installer writes the hook scripts to /etc/fast-webvnc/ and
  removes them on uninstall. Use --dns-auth-hook for other DNS providers.
  The letsencrypt-dns mode uses Certbot's manual DNS-01 hooks. The letsencrypt
  mode uses HTTP-01 via Certbot's webroot authenticator, so it requires a
  public DNS name that reaches this machine on TCP port 80. Both install an
  Nginx reload hook for renewals.
  Uninstall removes fast-webvnc files and the renewal hook, but leaves Certbot
  certificate lineages under /etc/letsencrypt for explicit certbot management.
  If install created the dedicated fast-webvnc system user, uninstall removes it
  after stopping the service.
EOF
}

usage_error() {
  error "$*"
  echo
  show_help
  exit "$EXIT_USAGE"
}

require_arg() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    usage_error "${option} requires a value."
  fi
}

# Parse the action word plus options. Every value option accepts both
# "--option value" and "--option=value" forms, hence the paired cases.
parse_args() {
  local seen_action=0

  while (($#)); do
    case "$1" in
      install|verify|status|rollback|uninstall|add-user|set-password|remove-user|logs|help)
        if (( seen_action )); then
          usage_error "Only one action may be specified."
        fi
        ACTION="$1"
        seen_action=1
        shift
        ;;
      --user)
        require_arg "$1" "${2:-}"
        WEB_USER="$2"
        shift 2
        ;;
      --user=*)
        WEB_USER="${1#*=}"
        shift
        ;;
      --password)
        require_arg "$1" "${2:-}"
        WEB_PASSWORD="$2"
        PASSWORD_FROM_ARG=1
        shift 2
        ;;
      --password=*)
        WEB_PASSWORD="${1#*=}"
        PASSWORD_FROM_ARG=1
        shift
        ;;
      --vnc-host)
        require_arg "$1" "${2:-}"
        VNC_HOST="$2"
        shift 2
        ;;
      --vnc-host=*)
        VNC_HOST="${1#*=}"
        shift
        ;;
      --vnc-port)
        require_arg "$1" "${2:-}"
        VNC_PORT="$2"
        shift 2
        ;;
      --vnc-port=*)
        VNC_PORT="${1#*=}"
        shift
        ;;
      --auto-vnc)
        AUTO_VNC_BACKEND=1
        shift
        ;;
      --no-auto-vnc)
        AUTO_VNC_BACKEND=0
        shift
        ;;
      --novnc-port)
        require_arg "$1" "${2:-}"
        NOVNC_PORT="$2"
        shift 2
        ;;
      --novnc-port=*)
        NOVNC_PORT="${1#*=}"
        shift
        ;;
      --https-port)
        require_arg "$1" "${2:-}"
        HTTPS_PORT="$2"
        shift 2
        ;;
      --https-port=*)
        HTTPS_PORT="${1#*=}"
        shift
        ;;
      --hostname)
        require_arg "$1" "${2:-}"
        HOSTNAME_VALUE="$2"
        HOSTNAME_EXPLICIT=1
        shift 2
        ;;
      --hostname=*)
        HOSTNAME_VALUE="${1#*=}"
        HOSTNAME_EXPLICIT=1
        shift
        ;;
      --service-user)
        require_arg "$1" "${2:-}"
        SERVICE_USER="$2"
        SERVICE_USER_EXPLICIT=1
        shift 2
        ;;
      --service-user=*)
        SERVICE_USER="${1#*=}"
        SERVICE_USER_EXPLICIT=1
        shift
        ;;
      --cert-mode)
        require_arg "$1" "${2:-}"
        CERT_MODE="$2"
        shift 2
        ;;
      --cert-mode=*)
        CERT_MODE="${1#*=}"
        shift
        ;;
      --cert-file)
        require_arg "$1" "${2:-}"
        PROVIDED_CERT_FILE="$2"
        CERT_MODE="provided"
        shift 2
        ;;
      --cert-file=*)
        PROVIDED_CERT_FILE="${1#*=}"
        CERT_MODE="provided"
        shift
        ;;
      --key-file)
        require_arg "$1" "${2:-}"
        PROVIDED_KEY_FILE="$2"
        CERT_MODE="provided"
        shift 2
        ;;
      --key-file=*)
        PROVIDED_KEY_FILE="${1#*=}"
        CERT_MODE="provided"
        shift
        ;;
      --cert-staging)
        CERT_STAGING=1
        CERT_STAGING_FLAG=1
        shift
        ;;
      --dns-auth-hook)
        require_arg "$1" "${2:-}"
        DNS_AUTH_HOOK="$2"
        shift 2
        ;;
      --dns-auth-hook=*)
        DNS_AUTH_HOOK="${1#*=}"
        shift
        ;;
      --dns-cleanup-hook)
        require_arg "$1" "${2:-}"
        DNS_CLEANUP_HOOK="$2"
        shift 2
        ;;
      --dns-cleanup-hook=*)
        DNS_CLEANUP_HOOK="${1#*=}"
        shift
        ;;
      --cf-api-token)
        require_arg "$1" "${2:-}"
        CF_API_TOKEN="$2"
        shift 2
        ;;
      --cf-api-token=*)
        CF_API_TOKEN="${1#*=}"
        shift
        ;;
      --cf-zone-id)
        require_arg "$1" "${2:-}"
        CF_ZONE_ID="$2"
        shift 2
        ;;
      --cf-zone-id=*)
        CF_ZONE_ID="${1#*=}"
        shift
        ;;
      --email)
        require_arg "$1" "${2:-}"
        LE_EMAIL="$2"
        shift 2
        ;;
      --email=*)
        LE_EMAIL="${1#*=}"
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --verbose|-v)
        VERBOSE=1
        shift
        ;;
      --help|-h)
        if (( seen_action )) && [[ "$ACTION" != "help" ]]; then
          usage_error "Do not combine --help with another action."
        fi
        ACTION="help"
        seen_action=1
        shift
        ;;
      *)
        usage_error "Unknown argument: $1"
        ;;
    esac
  done

  if [[ -z "$ACTION" ]]; then
    ACTION="help"
  fi
}

# ---- src/30-input-validation.sh ----

# 30-input-validation.sh — interactive prompts, validation of user-supplied
# values, and basic OS/root prechecks.

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "${prompt} [${default}]: " value
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  printf '%s' "$value"
}

prompt_password() {
  local first
  local second

  while true; do
    read -r -s -p "HTTPS password: " first
    echo
    read -r -s -p "Confirm HTTPS password: " second
    echo
    if [[ "$first" == "$second" && ${#first} -ge $MIN_PASSWORD_LENGTH ]]; then
      WEB_PASSWORD="$first"
      return
    fi
    warn "Passwords were shorter than ${MIN_PASSWORD_LENGTH} characters or did not match. Try again."
  done
}

valid_web_user_value() {
  local value="$1"
  [[ -n "$value" && "$value" != *:* && ! "$value" =~ [[:space:]] ]]
}

# Suggest a Basic Auth username: prefer the person who ran sudo, fall back
# through the usual login variables, and finally offer "vncadmin".
detect_web_user_default() {
  local candidate=""
  local uid_name=""

  for candidate in "${SUDO_USER:-}" "${DOAS_USER:-}" "${LOGNAME:-}" "${USER:-}"; do
    if [[ "$candidate" != "root" ]] && valid_web_user_value "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done

  if (( EUID != 0 )) && command -v id >/dev/null 2>&1; then
    uid_name="$(id -un 2>/dev/null || true)"
    if [[ "$uid_name" != "root" ]] && valid_web_user_value "$uid_name"; then
      printf '%s' "$uid_name"
      return
    fi
  fi

  printf '%s' "vncadmin"
}

prompt_username_if_needed() {
  if [[ -n "$WEB_USER" ]]; then
    return
  fi

  if (( NON_INTERACTIVE )); then
    die "$EXIT_USAGE" "--non-interactive requires --user or FAST_WEBVNC_USER."
  fi

  WEB_USER="$(prompt_with_default "HTTPS username" "$(detect_web_user_default)")"
}

detect_hostname_default() {
  local value=""

  if command -v hostname >/dev/null 2>&1; then
    value="$(hostname -f 2>/dev/null || true)"
    if [[ -z "$value" ]]; then
      value="$(hostname 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$value" ]]; then
    value="fast-webvnc.local"
  fi

  printf '%s' "$value"
}

detect_service_user_default() {
  printf '%s' "$DEFAULT_SERVICE_USER"
}

collect_install_inputs() {
  if [[ -z "$HOSTNAME_VALUE" ]]; then
    HOSTNAME_VALUE="$(detect_hostname_default)"
  fi

  if [[ -z "$SERVICE_USER" ]]; then
    SERVICE_USER="$(detect_service_user_default)"
  fi

  if (( NON_INTERACTIVE )); then
    if [[ -z "$WEB_USER" ]]; then
      die "$EXIT_USAGE" "--non-interactive requires --user or FAST_WEBVNC_USER."
    fi
    if [[ -z "$WEB_PASSWORD" ]]; then
      die "$EXIT_USAGE" "--non-interactive requires --password or FAST_WEBVNC_PASSWORD."
    fi
    return
  fi

  WEB_USER="$(prompt_with_default "HTTPS username" "${WEB_USER:-$(detect_web_user_default)}")"
  if [[ -z "$WEB_PASSWORD" ]]; then
    prompt_password
  fi
  VNC_HOST="$(prompt_with_default "VNC backend host" "$VNC_HOST")"
  VNC_PORT="$(prompt_with_default "VNC backend port" "$VNC_PORT")"
  NOVNC_PORT="$(prompt_with_default "Local noVNC port" "$NOVNC_PORT")"
  HTTPS_PORT="$(prompt_with_default "HTTPS port" "$HTTPS_PORT")"
  HOSTNAME_VALUE="$(prompt_with_default "Hostname for TLS/Nginx" "$HOSTNAME_VALUE")"
  SERVICE_USER="$(prompt_with_default "Service user" "$SERVICE_USER")"
  CERT_MODE="$(prompt_with_default "Certificate mode (self-signed, letsencrypt, letsencrypt-dns, provided)" "$CERT_MODE")"

  if [[ "$CERT_MODE" == "letsencrypt-placeholder" ]]; then
    CERT_MODE="letsencrypt"
  fi

  if is_letsencrypt_mode; then
    LE_EMAIL="$(prompt_with_default "Let's Encrypt email" "$LE_EMAIL")"
  fi

  if [[ "$CERT_MODE" == "letsencrypt-dns" ]]; then
    if [[ -z "$CF_API_TOKEN" && -z "$DNS_AUTH_HOOK" ]]; then
      CF_API_TOKEN="$(prompt_with_default "Cloudflare API token (DNS:Edit), or blank to provide a custom hook" "$CF_API_TOKEN")"
    fi
    if [[ -n "$CF_API_TOKEN" && -z "$CF_ZONE_ID" ]]; then
      CF_ZONE_ID="$(prompt_with_default "Cloudflare Zone ID" "$CF_ZONE_ID")"
    fi
    if [[ -z "$CF_API_TOKEN" ]]; then
      DNS_AUTH_HOOK="$(prompt_with_default "DNS-01 auth hook" "$DNS_AUTH_HOOK")"
      DNS_CLEANUP_HOOK="$(prompt_with_default "DNS-01 cleanup hook" "$DNS_CLEANUP_HOOK")"
    fi
  fi

  if [[ "$CERT_MODE" == "provided" ]]; then
    PROVIDED_CERT_FILE="$(prompt_with_default "Certificate file" "$PROVIDED_CERT_FILE")"
    PROVIDED_KEY_FILE="$(prompt_with_default "Private key file" "$PROVIDED_KEY_FILE")"
  fi
}

validate_port() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "$EXIT_USAGE" "${name} must be a numeric TCP port."
  fi

  if (( value < 1 || value > 65535 )); then
    die "$EXIT_USAGE" "${name} must be between 1 and 65535."
  fi
}

validate_web_user() {
  if ! valid_web_user_value "$WEB_USER"; then
    die "$EXIT_USAGE" "--user must be non-empty and cannot contain whitespace or ':'."
  fi
}

validate_web_password() {
  if [[ -z "$WEB_PASSWORD" ]]; then
    die "$EXIT_USAGE" "HTTPS Basic Auth password cannot be empty."
  fi

  if ((${#WEB_PASSWORD} < MIN_PASSWORD_LENGTH)); then
    die "$EXIT_USAGE" "HTTPS Basic Auth password must be at least ${MIN_PASSWORD_LENGTH} characters."
  fi

  if (( PASSWORD_FROM_ARG )); then
    warn "--password is visible via process listings while the installer runs. Prefer FAST_WEBVNC_PASSWORD or the interactive prompt."
  fi
}

is_ipv4() {
  local value="$1"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_local_host() {
  local value="$1"
  [[ "$value" == "localhost" || "$value" == "127.0.0.1" || "$value" == "0:0:0:0:0:0:0:1" || "$value" == "::1" ]]
}

is_letsencrypt_mode() {
  [[ "$CERT_MODE" == "letsencrypt" || "$CERT_MODE" == "letsencrypt-dns" ]]
}

is_trusted_cert_mode() {
  [[ "$CERT_MODE" == "letsencrypt" || "$CERT_MODE" == "letsencrypt-dns" || "$CERT_MODE" == "provided" ]]
}

# Rough check that a name could be issued a public certificate: it must be a
# dotted DNS name, not an IP, not .local, and each label must be well-formed.
is_public_dns_name() {
  local value="$1"
  local label
  local -a labels=()

  if is_ipv4 "$value" || [[ "$value" != *.* || "$value" == *.local || "$value" == *"_"* ]]; then
    return 1
  fi

  if ! [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]]; then
    return 1
  fi

  IFS='.' read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    if [[ -z "$label" || "$label" == -* || "$label" == *- ]]; then
      return 1
    fi
  done

  return 0
}

validate_install_options() {
  validate_port "--vnc-port" "$VNC_PORT"
  validate_port "--novnc-port" "$NOVNC_PORT"
  validate_port "--https-port" "$HTTPS_PORT"

  case "$AUTO_VNC_BACKEND" in
    1|true|TRUE|yes|YES|on|ON)
      AUTO_VNC_BACKEND=1
      ;;
    0|false|FALSE|no|NO|off|OFF|"")
      AUTO_VNC_BACKEND=0
      ;;
    *)
      die "$EXIT_USAGE" "--auto-vnc/FAST_WEBVNC_AUTO_VNC_BACKEND must be boolean."
      ;;
  esac

  if [[ "$VNC_HOST" == *:* ]]; then
    die "$EXIT_USAGE" "IPv6 VNC backend hosts are not supported by this installer version; use an IPv4 address or hostname."
  fi

  if ! [[ "$VNC_HOST" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "$EXIT_USAGE" "--vnc-host may contain only letters, numbers, dots, underscores, and hyphens."
  fi

  if [[ -z "$HOSTNAME_VALUE" ]]; then
    die "$EXIT_USAGE" "--hostname must be a hostname or IPv4 address."
  fi

  # Strict allowlist for every cert mode: the hostname is interpolated into the
  # generated Nginx server_name directive and into openssl -subj/-addext, so
  # whitespace and shell/Nginx metacharacters (;, {, }, #, $, /, :, newlines)
  # must be rejected to prevent config injection from untrusted hostname sources.
  if ! [[ "$HOSTNAME_VALUE" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "$EXIT_USAGE" "--hostname may contain only letters, numbers, dots, and hyphens (a hostname or IPv4 address), not a URL or special characters."
  fi

  validate_web_user

  validate_web_password

  if [[ -z "$SERVICE_USER" || ! "$SERVICE_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*[$]?$ ]]; then
    die "$EXIT_USAGE" "--service-user must be a valid local account name."
  fi

  if [[ "$CERT_MODE" == "letsencrypt-placeholder" ]]; then
    warn "--cert-mode letsencrypt-placeholder is deprecated; using letsencrypt."
    CERT_MODE="letsencrypt"
  fi

  case "$CERT_MODE" in
    dns-01|dns01)
      CERT_MODE="letsencrypt-dns"
      ;;
    byo|bring-your-own|custom)
      CERT_MODE="provided"
      ;;
  esac

  case "$CERT_MODE" in
    self-signed|letsencrypt|letsencrypt-dns|provided)
      ;;
    *)
      die "$EXIT_USAGE" "--cert-mode must be self-signed, letsencrypt, letsencrypt-dns, or provided."
      ;;
  esac

  if [[ -n "$CERT_STAGING_ENV" ]]; then
    case "$CERT_STAGING_ENV" in
      1|true|TRUE|yes|YES|on|ON|0|false|FALSE|no|NO|off|OFF)
        ;;
      *)
        die "$EXIT_USAGE" "FAST_WEBVNC_CERT_STAGING must be boolean."
        ;;
    esac
  fi

  if (( CERT_STAGING_FLAG )); then
    CERT_STAGING=1
  else
    case "$CERT_STAGING" in
      1|true|TRUE|yes|YES|on|ON)
        CERT_STAGING=1
        ;;
      0|false|FALSE|no|NO|off|OFF|"")
        CERT_STAGING=0
        ;;
      *)
        die "$EXIT_USAGE" "--cert-staging/FAST_WEBVNC_CERT_STAGING must be boolean."
        ;;
    esac
  fi
}

validate_letsencrypt_options() {
  if ! is_letsencrypt_mode; then
    return
  fi

  if (( ! HOSTNAME_EXPLICIT )); then
    die "$EXIT_USAGE" "Let's Encrypt mode requires --hostname with a public DNS name. $(dns01_guidance)"
  fi

  if ! is_public_dns_name "$HOSTNAME_VALUE"; then
    die "$EXIT_USAGE" "Let's Encrypt mode requires a public fully qualified domain name, not '${HOSTNAME_VALUE}'. $(dns01_guidance)"
  fi

  if [[ "$CERT_MODE" == "letsencrypt" && "$HTTPS_PORT" == "80" ]]; then
    die "$EXIT_USAGE" "Let's Encrypt mode reserves TCP port 80 for HTTP-01 validation; choose a different --https-port. $(dns01_guidance)"
  fi

  if [[ -z "$LE_EMAIL" || "$LE_EMAIL" != *@*.* ]]; then
    die "$EXIT_USAGE" "Let's Encrypt mode requires --email or FAST_WEBVNC_EMAIL. $(dns01_guidance)"
  fi

  if [[ "$CERT_MODE" == "letsencrypt-dns" && -z "$DNS_AUTH_HOOK" ]]; then
    if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" ]]; then
      die "$EXIT_USAGE" "letsencrypt-dns requires either --cf-api-token and --cf-zone-id (Cloudflare) or --dns-auth-hook (custom hook)."
    fi
  fi
}

warn_if_key_world_accessible() {
  local key_file="$1"
  local mode
  local group_digit
  local other_digit

  command -v stat >/dev/null 2>&1 || return 0

  mode="$(stat -Lc '%a' "$key_file" 2>/dev/null || true)"
  [[ -n "$mode" ]] || return 0

  group_digit="${mode: -2:1}"
  other_digit="${mode: -1}"
  if (( group_digit != 0 || other_digit != 0 )); then
    warn "Provided private key ${key_file} is group/world-accessible (mode ${mode}). The installer references it in place; restrict it with: chmod 600 ${key_file}"
  fi
}

validate_provided_cert_options() {
  if [[ "$CERT_MODE" != "provided" ]]; then
    return
  fi

  if [[ -z "$PROVIDED_CERT_FILE" || -z "$PROVIDED_KEY_FILE" ]]; then
    die "$EXIT_USAGE" "--cert-mode provided requires --cert-file and --key-file."
  fi

  if (( DRY_RUN )); then
    if [[ ! -f "$PROVIDED_CERT_FILE" ]]; then
      warn "Dry-run continuing although provided certificate does not exist here: ${PROVIDED_CERT_FILE}"
    fi
    if [[ ! -f "$PROVIDED_KEY_FILE" ]]; then
      warn "Dry-run continuing although provided private key does not exist here: ${PROVIDED_KEY_FILE}"
    elif [[ -f "$PROVIDED_KEY_FILE" ]]; then
      warn_if_key_world_accessible "$PROVIDED_KEY_FILE"
    fi
    return
  fi

  [[ -f "$PROVIDED_CERT_FILE" ]] || die "$EXIT_PRECHECK" "Provided certificate file not found: ${PROVIDED_CERT_FILE}"
  [[ -f "$PROVIDED_KEY_FILE" ]] || die "$EXIT_PRECHECK" "Provided private key file not found: ${PROVIDED_KEY_FILE}"
  warn_if_key_world_accessible "$PROVIDED_KEY_FILE"
}

require_root() {
  if (( EUID == 0 )); then
    return
  fi

  if (( DRY_RUN )); then
    warn "Dry-run continuing without root; the real action must be run with sudo/root."
    return
  fi

  die "$EXIT_PRECHECK" "Run this action as root, for example: sudo ./install.sh ${ACTION}"
}

require_debian_like() {
  local id=""
  local id_like=""

  if [[ -r /etc/os-release ]]; then
    id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
    id_like="$(awk -F= '$1 == "ID_LIKE" {gsub(/^"|"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
  fi

  case " ${id} ${id_like} " in
    *" debian "*|*" raspbian "*|*" ubuntu "*)
      ;;
    *)
      if (( DRY_RUN )); then
        warn "Dry-run continuing although this OS was not identified as Debian-like."
      else
        die "$EXIT_PRECHECK" "This installer supports Debian-like systems with apt and systemd. Detected ID='${id:-unknown}', ID_LIKE='${id_like:-unknown}'."
      fi
      ;;
  esac
}

detect_apt() {
  if command -v apt-get >/dev/null 2>&1; then
    APT_CMD="$(command -v apt-get)"
    return
  fi

  if command -v apt >/dev/null 2>&1; then
    APT_CMD="$(command -v apt)"
    return
  fi

  if (( DRY_RUN )); then
    warn "Dry-run continuing without apt/apt-get."
    APT_CMD="apt-get"
    return
  fi

  die "$EXIT_PRECHECK" "apt-get or apt is required."
}

require_command() {
  local command_name="$1"
  local remediation="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    return
  fi

  if (( DRY_RUN )); then
    warn "Dry-run continuing without command '${command_name}'."
    return
  fi

  die "$EXIT_PRECHECK" "Required command '${command_name}' is missing. ${remediation}"
}

validate_dns01_hooks() {
  if [[ "$CERT_MODE" != "letsencrypt-dns" ]]; then
    return
  fi

  if (( DRY_RUN )); then
    if [[ ! -x "$DNS_AUTH_HOOK" ]]; then
      warn "Dry-run continuing although DNS-01 auth hook is not executable here: ${DNS_AUTH_HOOK}"
    fi
    if [[ -n "$DNS_CLEANUP_HOOK" && ! -x "$DNS_CLEANUP_HOOK" ]]; then
      warn "Dry-run continuing although DNS-01 cleanup hook is not executable here: ${DNS_CLEANUP_HOOK}"
    fi
    return
  fi

  [[ -x "$DNS_AUTH_HOOK" ]] || die "$EXIT_PRECHECK" "DNS-01 auth hook must exist and be executable: ${DNS_AUTH_HOOK}"
  if [[ -n "$DNS_CLEANUP_HOOK" && ! -x "$DNS_CLEANUP_HOOK" ]]; then
    die "$EXIT_PRECHECK" "DNS-01 cleanup hook must be executable when provided: ${DNS_CLEANUP_HOOK}"
  fi
}

preflight_base() {
  require_debian_like
  detect_apt
  require_command systemctl "Install systemd or run on a systemd-based Raspberry Pi OS/Debian host."
  require_command timeout "Install coreutils."
}

# ---- src/40-preflight-runtime.sh ----

# 40-preflight-runtime.sh — package installation, the dedicated service user,
# and detection of runtime values (LAN IPs, hostnames, the noVNC web root).

run_apt() {
  if (( DRY_RUN )); then
    info "DRY-RUN: DEBIAN_FRONTEND=noninteractive ${APT_CMD} $*"
    return 0
  fi

  DEBIAN_FRONTEND=noninteractive "$APT_CMD" "$@"
}

install_packages() {
  local packages=(
    novnc
    websockify
    nginx
    apache2-utils
    openssl
    curl
    iproute2
  )

  if is_letsencrypt_mode; then
    packages+=(certbot)
  fi

  info "Installing required packages: ${packages[*]}"
  run_apt update
  run_apt install -y "${packages[@]}"
}

ensure_post_package_commands() {
  require_command websockify "Install the websockify package."
  WEBSOCKIFY_BIN="$(command -v websockify 2>/dev/null || true)"
  if [[ -z "$WEBSOCKIFY_BIN" ]]; then
    if (( DRY_RUN )); then
      WEBSOCKIFY_BIN="/usr/bin/websockify"
    else
      die "$EXIT_PRECHECK" "Could not resolve websockify path."
    fi
  fi
  require_command nginx "Install the nginx package."
  require_command htpasswd "Install the apache2-utils package."
  require_command openssl "Install the openssl package."
  require_command curl "Install the curl package."
  require_command ss "Install the iproute2 package."

  if is_letsencrypt_mode; then
    require_command certbot "Install the certbot package."
  fi
}

# Make sure the account that will run websockify exists. We remember whether
# we created it (in the state file) so uninstall knows whether to remove it.
ensure_service_user() {
  local prior_created=""
  local prior_user=""

  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    if [[ -f "$STATE_FILE" ]]; then
      prior_created="$(awk -F= '$1 == "SERVICE_USER_CREATED" {print $2; exit}' "$STATE_FILE" 2>/dev/null || true)"
      prior_user="$(awk -F= '$1 == "SERVICE_USER" {print $2; exit}' "$STATE_FILE" 2>/dev/null || true)"
      if [[ "$prior_created" == "1" && "$prior_user" == "$SERVICE_USER" ]]; then
        SERVICE_USER_CREATED=1
      fi
    fi
    return
  fi

  if (( SERVICE_USER_EXPLICIT )); then
    die "$EXIT_PRECHECK" "Service user '${SERVICE_USER}' does not exist. Create it or choose another --service-user."
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: create dedicated system user ${SERVICE_USER}"
    return
  fi

  require_command useradd "Install the passwd package or create ${SERVICE_USER} manually."

  info "Creating dedicated system user ${SERVICE_USER}"
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
  SERVICE_USER_CREATED=1
}

detect_lan_ips() {
  local output=""
  local ip
  local -a ips=()

  if command -v hostname >/dev/null 2>&1; then
    output="$(hostname -I 2>/dev/null || true)"
    for ip in $output; do
      if is_ipv4 "$ip"; then
        ips+=("$ip")
      fi
    done
  fi

  if ((${#ips[@]} == 0)) && command -v ip >/dev/null 2>&1; then
    while IFS= read -r ip; do
      if [[ -n "$ip" ]]; then
        ips+=("$ip")
      fi
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' || true)
  fi

  if ((${#ips[@]})); then
    printf '%s\n' "${ips[@]}"
  fi
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

append_unique() {
  local -n target_array="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    return
  fi

  if ! array_contains "$value" "${target_array[@]}"; then
    target_array+=("$value")
  fi
}

# Work out every name and address this machine answers to, then derive the
# Nginx server_name list, the certificate SAN list, the active cert/key paths,
# and the endpoint URL we print at the end of the install.
build_runtime_names() {
  local -a server_names=()
  local -a sans=()
  local -a ips=()
  local ip
  local short_hostname=""

  if [[ -z "$HOSTNAME_VALUE" ]]; then
    HOSTNAME_VALUE="$(detect_hostname_default)"
  fi

  mapfile -t ips < <(detect_lan_ips)

  if is_letsencrypt_mode; then
    LE_CERT_NAME="$HOSTNAME_VALUE"
    ACTIVE_CERT_FILE="/etc/letsencrypt/live/${LE_CERT_NAME}/fullchain.pem"
    ACTIVE_KEY_FILE="/etc/letsencrypt/live/${LE_CERT_NAME}/privkey.pem"
    NGINX_SERVER_NAMES="$HOSTNAME_VALUE"
    SAN_LIST="DNS:${HOSTNAME_VALUE}"
    ENDPOINT_URL="$(format_url "$HOSTNAME_VALUE" "$HTTPS_PORT")"
    if [[ "$HTTPS_PORT" == "443" ]]; then
      HTTP_REDIRECT_TARGET="https://\$host\$request_uri"
    else
      HTTP_REDIRECT_TARGET="https://\$host:${HTTPS_PORT}\$request_uri"
    fi
    return
  fi

  if [[ "$CERT_MODE" == "provided" ]]; then
    ACTIVE_CERT_FILE="$PROVIDED_CERT_FILE"
    ACTIVE_KEY_FILE="$PROVIDED_KEY_FILE"
  else
    ACTIVE_CERT_FILE="$CERT_FILE"
    ACTIVE_KEY_FILE="$KEY_FILE"
  fi

  append_unique server_names "$HOSTNAME_VALUE"

  if ! is_ipv4 "$HOSTNAME_VALUE" && [[ "$HOSTNAME_VALUE" != *.* ]]; then
    append_unique server_names "${HOSTNAME_VALUE}.local"
  fi

  if [[ "$HOSTNAME_VALUE" == *.* && ! "$HOSTNAME_VALUE" =~ ^[0-9.]+$ ]]; then
    short_hostname="${HOSTNAME_VALUE%%.*}"
    append_unique server_names "$short_hostname"
  fi

  for ip in "${ips[@]}"; do
    append_unique server_names "$ip"
  done

  if ((${#server_names[@]} == 0)); then
    server_names=("fast-webvnc.local")
  fi

  for ip in "${server_names[@]}"; do
    if is_ipv4 "$ip"; then
      append_unique sans "IP:${ip}"
    else
      append_unique sans "DNS:${ip}"
    fi
  done

  if ((${#sans[@]} == 0)); then
    sans=("DNS:fast-webvnc.local")
  fi

  NGINX_SERVER_NAMES="${server_names[*]}"
  SAN_LIST="$(IFS=,; printf '%s' "${sans[*]}")"
  ENDPOINT_URL="$(format_url "$HOSTNAME_VALUE" "$HTTPS_PORT")"
}

format_url() {
  local host="$1"
  local port="$2"

  if [[ "$port" == "443" ]]; then
    printf 'https://%s/vnc.html?resize=scale&path=websockify' "$host"
  else
    printf 'https://%s:%s/vnc.html?resize=scale&path=websockify' "$host" "$port"
  fi
}

detect_novnc_web_root() {
  local candidate
  local candidates=(
    /usr/share/novnc
    /usr/share/novnc/web
    /usr/share/noVNC
    /usr/share/noVNC/web
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}/vnc.html" ]]; then
      NOVNC_WEB_ROOT="$candidate"
      return
    fi
  done

  if command -v find >/dev/null 2>&1; then
    candidate="$(find /usr/share -maxdepth 4 -type f -name vnc.html 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
      NOVNC_WEB_ROOT="${candidate%/vnc.html}"
      return
    fi
  fi

  if (( DRY_RUN )); then
    NOVNC_WEB_ROOT="/usr/share/novnc"
    warn "Dry-run using expected noVNC web root ${NOVNC_WEB_ROOT}; package files are not installed here."
    return
  fi

  die "$EXIT_PRECHECK" "Could not find noVNC vnc.html. Reinstall the novnc package."
}

# ---- src/50-network-vnc.sh ----

# 50-network-vnc.sh — VNC backend detection, automatic Raspberry Pi VNC
# (WayVNC/RealVNC) setup and hardening, and listener/port conflict checks.

vnc_protocol_responds() {
  local host="$1"
  local port="$2"

  # A plain TCP listener is not enough: websockify/noVNC need an RFB banner.
  # shellcheck disable=SC2016
  timeout 5 bash -c '
    exec 3<>"/dev/tcp/$1/$2" || exit 1
    IFS= read -r -N 12 banner <&3 || exit 1
    [[ "$banner" == RFB\ * ]]
  ' _ "$host" "$port" >/dev/null 2>&1
}

vnc_listener_host_is_loopback() {
  local host_part="$1"

  case "$host_part" in
    127.*|localhost|::1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

vnc_listener_summary() {
  local listeners=""

  listeners="$(list_listeners_on_port "$VNC_PORT" || true)"
  if [[ -z "$listeners" ]]; then
    printf 'none'
    return
  fi

  printf '%s' "${listeners//$'\n'/, }"
}

vnc_listeners_loopback_only() {
  local listeners=""
  local listener
  local host_part
  local seen=0

  listeners="$(list_listeners_on_port "$VNC_PORT" || true)"
  if [[ -z "$listeners" ]]; then
    return 1
  fi

  while IFS= read -r listener; do
    [[ -z "$listener" ]] && continue
    seen=1
    host_part="$(listener_host_part "$listener")"
    if ! vnc_listener_host_is_loopback "$host_part"; then
      return 1
    fi
  done <<<"$listeners"

  (( seen ))
}

require_vnc_loopback_only() {
  if ! is_local_host "$VNC_HOST"; then
    warn "Configured VNC backend host is '${VNC_HOST}', not localhost. Traffic between websockify and VNC may leave this machine."
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: require VNC backend to listen only on loopback"
    return
  fi

  if ! command -v ss >/dev/null 2>&1; then
    warn "Could not verify that VNC is loopback-only because ss is unavailable."
    return
  fi

  if vnc_listeners_loopback_only; then
    return
  fi

  die "$EXIT_PRECHECK" "VNC is reachable at ${VNC_HOST}:${VNC_PORT}, but the listener is not restricted to loopback (${VNC_PORT}: $(vnc_listener_summary)). Bind Raspberry Pi VNC to 127.0.0.1 before proxying it through noVNC."
}

vnc_remediation_text() {
  local auto_text

  if (( AUTO_VNC_BACKEND )); then
    auto_text="The installer tried to enable and harden Raspberry Pi VNC automatically, but no loopback-only VNC backend became reachable."
  else
    auto_text="Automatic VNC backend setup is disabled; start or enable a VNC backend first."
  fi

  cat <<EOF
No VNC server is reachable at ${VNC_HOST}:${VNC_PORT}.

${auto_text}

Common fixes:
  WayVNC: enable VNC in Raspberry Pi Configuration or raspi-config, then make
          sure it listens on 127.0.0.1:${VNC_PORT}.
  Wayland: log into a labwc/Sway desktop before installing. Automatic setup
          runs WayVNC as the desktop user. GNOME/KDE need a separate VNC
          backend (RDP-only desktop sharing cannot be used by noVNC).
  RealVNC (X11): enable the VNC interface, or check:
          sudo systemctl status vncserver-x11-serviced.service

After the backend is reachable, re-run this installer.
EOF
}

wait_for_vnc_backend() {
  local attempts="${1:-10}"
  local delay="${2:-1}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if vnc_protocol_responds "$VNC_HOST" "$VNC_PORT"; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

mark_managed_vnc_backend_if_present() {
  if managed_file_has_marker "$VNC_BACKEND_SERVICE_FILE"; then
    VNC_BACKEND_MANAGED=1
  fi
}

systemd_unit_exists() {
  local unit="$1"
  local output=""

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  output="$(systemctl list-unit-files "$unit" --no-legend 2>/dev/null || true)"
  [[ -n "$output" ]] || systemctl cat "$unit" >/dev/null 2>&1
}

# WayVNC reads config from several places depending on how it is launched:
# the system path, root's home, and per-user homes. List every candidate so
# hardening and backup cover whichever one is actually in use.
wayvnc_config_paths() {
  local home
  local sudo_home=""

  printf '%s\n' "$PI_WAYVNC_CONFIG_FILE"
  printf '%s\n' "/root/.config/wayvnc/config"

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && command -v getent >/dev/null 2>&1; then
    sudo_home="$(getent passwd "$SUDO_USER" | awk -F: '{print $6}' || true)"
    if [[ -n "$sudo_home" && -d "$sudo_home" ]]; then
      printf '%s\n' "${sudo_home}/.config/wayvnc/config"
    fi
  fi

  if [[ -r /etc/passwd ]]; then
    while IFS= read -r home; do
      [[ -n "$home" && -d "$home" ]] || continue
      printf '%s\n' "${home}/.config/wayvnc/config"
    done < <(awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\// {print $6}' /etc/passwd)
  fi
}

# Set key=value in a simple config file: replace any existing uncommented
# entry for the key (keeping comments intact) or append it, preserving the
# file's permissions.
harden_config_key() {
  local path="$1"
  local key="$2"
  local value="$3"
  local mode="0644"
  local tmp

  if (( DRY_RUN )); then
    info "DRY-RUN: set ${key}=${value} in ${path}"
    return
  fi

  mkdir -p "$(dirname "$path")"
  if [[ -e "$path" || -L "$path" ]]; then
    mode="$(stat -Lc '%a' "$path" 2>/dev/null || printf '0644')"
  else
    : > "$path"
  fi

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { written = 0 }
    /^[[:space:]]*#/ { print; next }
    {
      raw_key = $0
      sub(/[=].*$/, "", raw_key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw_key)
      if (raw_key == key) {
        if (!written) {
          print key "=" value
          written = 1
        }
        next
      }
      print
    }
    END {
      if (!written) {
        print key "=" value
      }
    }
  ' "$path" > "$tmp"

  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

harden_wayvnc_config() {
  local path

  if ! command -v wayvnc >/dev/null 2>&1 && ! systemd_unit_exists wayvnc.service && [[ ! -e "$PI_WAYVNC_CONFIG_FILE" && ! -d "$(dirname "$PI_WAYVNC_CONFIG_FILE")" ]]; then
    return 1
  fi

  info "Hardening Raspberry Pi WayVNC for loopback-only noVNC proxying"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    harden_config_key "$path" address 127.0.0.1
    harden_config_key "$path" port "$VNC_PORT"
    harden_config_key "$path" enable_auth false
  done < <(wayvnc_config_paths | awk '!seen[$0]++')
  return 0
}

harden_realvnc_config() {
  if ! systemd_unit_exists vncserver-x11-serviced.service && ! command -v vncserver-x11 >/dev/null 2>&1 && [[ ! -e "$PI_REALVNC_CONFIG_FILE" ]]; then
    return 1
  fi

  info "Hardening Raspberry Pi RealVNC for loopback-only noVNC proxying"
  # Authentication/encryption are handled at the HTTPS layer; the VNC side
  # must speak plain RFB for noVNC, which is safe on a loopback-only listener.
  harden_config_key "$PI_REALVNC_CONFIG_FILE" localhost TRUE
  harden_config_key "$PI_REALVNC_CONFIG_FILE" IpListenAddresses 127.0.0.1
  harden_config_key "$PI_REALVNC_CONFIG_FILE" RfbPort "$VNC_PORT"
  harden_config_key "$PI_REALVNC_CONFIG_FILE" Authentication None
  harden_config_key "$PI_REALVNC_CONFIG_FILE" Encryption AlwaysOff
  return 0
}

harden_raspberry_pi_vnc_configs() {
  local hardened=0

  harden_wayvnc_config && hardened=1
  harden_realvnc_config && hardened=1

  if (( hardened )); then
    return 0
  fi

  warn "No Raspberry Pi WayVNC or RealVNC configuration target was detected."
  return 1
}

pi_vnc_unit_names() {
  printf '%s\n' wayvnc.service vncserver-x11-serviced.service
}

stop_pi_vnc_units() {
  local unit

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if systemd_unit_exists "$unit"; then
      if (( DRY_RUN )); then
        info "DRY-RUN: systemctl stop ${unit}"
      else
        systemctl stop "$unit" >/dev/null 2>&1 || true
      fi
    fi
  done < <(pi_vnc_unit_names)
}

disable_pi_vnc_units() {
  local unit

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if systemd_unit_exists "$unit"; then
      if (( DRY_RUN )); then
        info "DRY-RUN: systemctl stop ${unit}"
        info "DRY-RUN: systemctl disable ${unit}"
      else
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
      fi
    fi
  done < <(pi_vnc_unit_names)
}

restart_active_pi_vnc_units() {
  local unit

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      if (( DRY_RUN )); then
        info "DRY-RUN: systemctl restart ${unit}"
      else
        systemctl restart "$unit" >/dev/null 2>&1 || warn "Could not restart ${unit} after restoring Raspberry Pi VNC config."
      fi
    fi
  done < <(pi_vnc_unit_names)
}

restart_pi_vnc_units() {
  local unit
  local started=0

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if ! systemd_unit_exists "$unit"; then
      continue
    fi

    info "Starting hardened Raspberry Pi VNC service ${unit}"
    if (( DRY_RUN )); then
      info "DRY-RUN: systemctl enable ${unit}"
      info "DRY-RUN: systemctl restart ${unit}"
      started=1
      continue
    fi

    if systemctl enable "$unit" >/dev/null 2>&1 && systemctl restart "$unit"; then
      started=1
    else
      warn "Could not start ${unit}."
    fi
  done < <(pi_vnc_unit_names)

  (( started ))
}

start_hardened_raspberry_pi_vnc() {
  if (( DRY_RUN )); then
    info "DRY-RUN: configure WayVNC for an available Wayland desktop, or enable and harden Raspberry Pi VNC for ${VNC_HOST}:${VNC_PORT}"
    return 0
  fi

  harden_raspberry_pi_vnc_configs || return 1
  stop_pi_vnc_units
  restart_pi_vnc_units || return 1
  if wait_for_vnc_backend 10 1 && vnc_listeners_loopback_only; then
    PI_VNC_AUTOMANAGED=1
    return 0
  fi

  return 1
}

try_enable_raspberry_pi_vnc() {
  if ! command -v raspi-config >/dev/null 2>&1; then
    return 1
  fi

  info "Enabling and hardening the Raspberry Pi VNC interface"

  if (( DRY_RUN )); then
    info "DRY-RUN: raspi-config nonint do_vnc 0"
    return 0
  fi

  if ! raspi-config nonint do_vnc 0; then
    warn "raspi-config could not enable the Raspberry Pi VNC interface."
    return 1
  fi

  start_hardened_raspberry_pi_vnc
}

try_start_vnc_unit() {
  local unit="$1"

  if ! systemd_unit_exists "$unit"; then
    return 1
  fi

  info "Attempting to start hardened Raspberry Pi VNC service ${unit}"

  if (( DRY_RUN )); then
    info "DRY-RUN: systemctl start ${unit}"
    info "DRY-RUN: systemctl enable ${unit}"
    return 0
  fi

  start_hardened_raspberry_pi_vnc
}

try_start_raspberry_pi_vnc_services() {
  local unit
  local -a units=(
    wayvnc.service
    vncserver-x11-serviced.service
  )

  for unit in "${units[@]}"; do
    if try_start_vnc_unit "$unit"; then
      return 0
    fi
  done

  return 1
}

# Discover sockets rather than trusting sudo's stripped desktop environment.
# Refuse ambiguous desktops instead of sharing an arbitrary user's screen.
find_wayland_session() {
  local socket uid owner
  local count=0
  WAYLAND_BACKEND_UID=""
  WAYLAND_BACKEND_DISPLAY=""
  for socket in /run/user/[0-9]*/wayland-*; do
    [[ -S "$socket" ]] || continue
    [[ "${socket##*/}" =~ ^wayland-[0-9]+$ ]] || continue
    uid="${socket#/run/user/}"
    uid="${uid%%/*}"
    [[ "$(stat -c %u "$socket")" == "$uid" ]] || continue
    owner="$(getent passwd "$uid" | cut -d: -f1)"
    [[ -n "$owner" && "$uid" != 0 ]] || continue
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root && "$owner" != "$SUDO_USER" ]]; then
      continue
    fi
    WAYLAND_BACKEND_UID="$uid"
    WAYLAND_BACKEND_DISPLAY="${socket##*/}"
    count=$((count + 1))
  done
  if (( count != 1 )); then
    if (( count > 1 )); then
      warn "Multiple Wayland displays found; start WayVNC in the intended desktop and re-run with --no-auto-vnc."
    fi
    return 1
  fi
}

try_start_wayland_backend() {
  local binary tmp

  find_wayland_session || return 1
  # A distro service already owns startup on Raspberry Pi; leave it to the
  # existing configuration/hardening path rather than starting a competitor.
  if systemd_unit_exists wayvnc.service; then
    return 1
  fi
  if [[ -e "$VNC_BACKEND_SERVICE_FILE" ]] && ! managed_file_has_marker "$VNC_BACKEND_SERVICE_FILE"; then
    warn "Refusing to overwrite unmanaged ${VNC_BACKEND_SERVICE_FILE}."
    return 1
  fi
  if ! command -v wayvnc >/dev/null 2>&1; then
    run_apt install -y wayvnc
  fi
  binary="$(command -v wayvnc)" || return 1
  [[ "$binary" =~ ^/[a-zA-Z0-9/_.-]+$ ]] || return 1
  info "Starting WayVNC for user ID ${WAYLAND_BACKEND_UID} on ${WAYLAND_BACKEND_DISPLAY}"
  tmp="$(mktemp)"
  # Retain the legacy backend unit name for state/rollback compatibility.
  # An empty config avoids inheriting desktop authentication or LAN binding.
  cat > "$tmp" <<EOF
# Managed by fast-webvnc. Local changes may be overwritten by install.sh.
[Unit]
Description=Fast WebVNC Wayland desktop backend
After=graphical.target
StartLimitIntervalSec=0

[Service]
User=${WAYLAND_BACKEND_UID}
Environment=XDG_RUNTIME_DIR=/run/user/${WAYLAND_BACKEND_UID}
Environment=WAYLAND_DISPLAY=${WAYLAND_BACKEND_DISPLAY}
ExecStart=${binary} --config=/dev/null 127.0.0.1 ${VNC_PORT}
Restart=always
RestartSec=5
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=graphical.target
EOF
  install -m 0644 "$tmp" "$VNC_BACKEND_SERVICE_FILE"
  rm -f "$tmp"
  VNC_BACKEND_MANAGED=1
  if systemctl daemon-reload &&
    systemctl enable "$VNC_BACKEND_SERVICE_NAME" &&
    systemctl restart "$VNC_BACKEND_SERVICE_NAME" &&
    wait_for_vnc_backend 10 1 && vnc_listeners_loopback_only; then
    return 0
  fi
  systemctl stop "$VNC_BACKEND_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$VNC_BACKEND_SERVICE_NAME" >/dev/null 2>&1 || true
  warn "WayVNC could not attach to the desktop. Check journalctl -u ${VNC_BACKEND_SERVICE_NAME}. GNOME/KDE require a separate VNC backend; WayVNC supports wlroots compositors such as labwc and Sway."
  return 1
}

# The main VNC backend gate for install: confirm a VNC server answers on the
# configured host/port and (for localhost) that it only listens on loopback.
# If nothing answers and auto-setup is allowed, try to enable and harden the
# Raspberry Pi VNC service before giving up with remediation advice.
ensure_vnc_backend() {
  info "Checking VNC backend at ${VNC_HOST}:${VNC_PORT}"

  if vnc_protocol_responds "$VNC_HOST" "$VNC_PORT"; then
    mark_managed_vnc_backend_if_present
    if is_local_host "$VNC_HOST" && (( AUTO_VNC_BACKEND )) && command -v ss >/dev/null 2>&1 && ! vnc_listeners_loopback_only; then
      warn "VNC is reachable at ${VNC_HOST}:${VNC_PORT}, but it is not loopback-only (${VNC_PORT}: $(vnc_listener_summary)); hardening Raspberry Pi VNC automatically."
      if start_hardened_raspberry_pi_vnc; then
        require_vnc_loopback_only
        info "VNC backend is reachable and loopback-only at ${VNC_HOST}:${VNC_PORT}"
        return
      fi
      die "$EXIT_PRECHECK" "VNC is reachable at ${VNC_HOST}:${VNC_PORT}, but automatic Raspberry Pi VNC hardening did not make it loopback-only (${VNC_PORT}: $(vnc_listener_summary))."
    fi
    require_vnc_loopback_only
    return
  fi

  if (( ! AUTO_VNC_BACKEND )); then
    die "$EXIT_PRECHECK" "$(vnc_remediation_text)"
  fi

  if ! is_local_host "$VNC_HOST"; then
    die "$EXIT_PRECHECK" "No VNC server is reachable at ${VNC_HOST}:${VNC_PORT}. Automatic backend setup only supports localhost; start the remote VNC backend or use --vnc-host 127.0.0.1."
  fi

  warn "No VNC backend is reachable at ${VNC_HOST}:${VNC_PORT}; attempting automatic setup."

  if (( DRY_RUN )); then
    info "DRY-RUN: configure WayVNC for an available Wayland desktop, or enable and harden Raspberry Pi VNC for ${VNC_HOST}:${VNC_PORT}"
    require_vnc_loopback_only
    return
  fi

  if try_start_wayland_backend || try_enable_raspberry_pi_vnc || try_start_raspberry_pi_vnc_services; then
    require_vnc_loopback_only
    info "VNC backend is reachable at ${VNC_HOST}:${VNC_PORT}"
    mark_managed_vnc_backend_if_present
    return
  fi

  die "$EXIT_PRECHECK" "$(vnc_remediation_text)"
}

list_listeners_on_port() {
  local port="$1"

  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  ss -H -ltn 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {print $4}'
}

list_listener_lines_on_port() {
  local port="$1"

  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  ss -H -ltnp 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {print}'
}

managed_file_has_marker() {
  local path="$1"

  [[ -f "$path" ]] && grep -q "Managed by fast-webvnc" "$path" 2>/dev/null
}

state_exists() {
  [[ -f "$STATE_FILE" ]]
}

check_port_conflicts() {
  local listeners=""
  local lines=""
  local http_lines=""

  if ! command -v ss >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      warn "Dry-run cannot check port conflicts because ss is unavailable."
      return
    fi
    die "$EXIT_PRECHECK" "ss is required to check port conflicts. Install iproute2."
  fi

  listeners="$(list_listeners_on_port "$NOVNC_PORT" || true)"
  if [[ -n "$listeners" ]]; then
    if state_exists || managed_file_has_marker "$SERVICE_FILE"; then
      warn "Local noVNC port ${NOVNC_PORT} is already in use by an existing fast-webvnc install; it will be restarted."
    else
      die "$EXIT_PRECHECK" "Local noVNC port ${NOVNC_PORT} is already in use. Choose --novnc-port or stop the conflicting service."
    fi
  fi

  lines="$(list_listener_lines_on_port "$HTTPS_PORT" || true)"
  if [[ -n "$lines" ]]; then
    if grep -qi 'nginx' <<<"$lines"; then
      info "HTTPS port ${HTTPS_PORT} is already served by Nginx. The fast-webvnc site will be added without disabling unrelated sites."
    else
      die "$EXIT_PRECHECK" "HTTPS port ${HTTPS_PORT} is already in use by a non-Nginx process. Choose --https-port or stop the conflicting service."
    fi
  fi

  if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    http_lines="$(list_listener_lines_on_port 80 || true)"
    if [[ -n "$http_lines" ]]; then
      if grep -qi 'nginx' <<<"$http_lines"; then
        warn "TCP port 80 is already served by Nginx. The HTTP-01 ACME challenge server block will be added for ${HOSTNAME_VALUE}. $(dns01_guidance)"
      else
        die "$EXIT_PRECHECK" "Let's Encrypt HTTP-01 validation needs TCP port 80, but a non-Nginx process is listening there. Stop it or move it before installing, or use DNS-01 instead. $(dns01_guidance)"
      fi
    fi
  fi
}

listener_host_part() {
  local listener="$1"
  local host_part

  if [[ "$listener" == \[*\]:* ]]; then
    host_part="${listener#\[}"
    host_part="${host_part%\]:*}"
    printf '%s' "$host_part"
    return
  fi

  host_part="${listener%:*}"
  printf '%s' "$host_part"
}

warn_if_vnc_exposed() {
  local listeners=""
  local listener
  local host_part

  if ! command -v ss >/dev/null 2>&1; then
    return
  fi

  listeners="$(list_listeners_on_port "$VNC_PORT" || true)"
  if [[ -z "$listeners" ]]; then
    return
  fi

  while IFS= read -r listener; do
    [[ -z "$listener" ]] && continue
    host_part="$(listener_host_part "$listener")"
    case "$host_part" in
      127.*|localhost|::1)
        ;;
      0.0.0.0|::|\*|0:0:0:0:0:0:0:0)
        warn "VNC appears to be listening on all interfaces (${listener}). Prefer binding the VNC backend to localhost."
        ;;
      *)
        warn "VNC appears to be exposed on ${listener}. Prefer binding the VNC backend to 127.0.0.1."
        ;;
    esac
  done <<<"$listeners"

  if ! is_local_host "$VNC_HOST"; then
    warn "Configured VNC backend host is '${VNC_HOST}', not localhost. Traffic between websockify and VNC may leave this machine."
  fi
}

warn_if_letsencrypt_dns_unresolved() {
  local addresses=""

  if [[ "$CERT_MODE" != "letsencrypt" ]]; then
    return
  fi

  if ! command -v getent >/dev/null 2>&1; then
    warn "Could not check DNS for ${HOSTNAME_VALUE}; getent is unavailable."
    return
  fi

  addresses="$(getent ahosts "$HOSTNAME_VALUE" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  if [[ -z "$addresses" ]]; then
    warn "DNS for ${HOSTNAME_VALUE} did not resolve from this host. Certbot HTTP-01 may fail unless public DNS is already configured. $(dns01_guidance)"
    return
  fi

  debug "DNS for ${HOSTNAME_VALUE}: ${addresses//$'\n'/ }"
}

detect_vnc_provider() {
  local -a providers=()
  local unit
  local process_list=""

  if (( DRY_RUN )); then
    info "DRY-RUN: detect Raspberry Pi VNC provider after startup"
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    for unit in wayvnc.service vncserver-x11-serviced.service; do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        providers+=("$unit")
      fi
    done
  fi

  if command -v pgrep >/dev/null 2>&1; then
    process_list="$(pgrep -af 'wayvnc|vncserver-x11|realvnc' 2>/dev/null | grep -Ev 'pgrep -af|install\.sh|fast-webvnc' || true)"
    if grep -qi 'wayvnc' <<<"$process_list"; then
      providers+=("WayVNC process")
    fi
    if grep -qi 'vncserver-x11\|realvnc' <<<"$process_list"; then
      providers+=("RealVNC process")
    fi
  fi

  if ((${#providers[@]})); then
    info "Detected likely VNC provider: ${providers[*]}"
  else
    warn "VNC is reachable, but Raspberry Pi VNC provider detection did not identify WayVNC or RealVNC. Continuing."
  fi
}

# ---- src/60-backup-rollback.sh ----

# 60-backup-rollback.sh — backups of every file the installer touches,
# rollback from those backups, and safety guards around file removal.

# Allowlist of paths the installer is ever allowed to delete or restore.
# remove_path() refuses anything not on this list, so a corrupted state file
# or backup manifest can never trick rollback/uninstall into rm -rf'ing
# something we don't own. Keep in sync with the paths in 00-bootstrap.sh.
safe_managed_path() {
  local path="$1"

  case "$path" in
    /etc/systemd/system/fast-webvnc.service|/etc/systemd/system/fast-webvnc-x11vnc.service|/etc/wayvnc/config|/root/.config/wayvnc/config|/home/*/.config/wayvnc/config|/root/.vnc/config.d/vncserver-x11|/etc/nginx/sites-available/fast-webvnc|/etc/nginx/sites-enabled/fast-webvnc|/etc/fast-webvnc/htpasswd|/etc/fast-webvnc/certs/fast-webvnc.crt|/etc/fast-webvnc/certs/fast-webvnc.key|/var/lib/fast-webvnc/state.env|/etc/letsencrypt/renewal-hooks/deploy/fast-webvnc-reload-nginx|/etc/fast-webvnc/cf-credentials|/etc/fast-webvnc/cf-dns-auth|/etc/fast-webvnc/cf-dns-cleanup)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remove_path() {
  local path="$1"

  if ! safe_managed_path "$path"; then
    die "$EXIT_ROLLBACK" "Refusing to remove unexpected path during rollback/uninstall: ${path}"
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: remove ${path}"
    return
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
  fi
}

prepare_backup_dir() {
  local timestamp

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  BACKUP_DIR_CURRENT="${BACKUP_ROOT}/${timestamp}"

  if (( DRY_RUN )); then
    info "DRY-RUN: create backup directory ${BACKUP_DIR_CURRENT}"
    return
  fi

  mkdir -p "${BACKUP_DIR_CURRENT}/files"
  chmod 0700 "$BACKUP_DIR_CURRENT"
  : > "${BACKUP_DIR_CURRENT}/manifest.tsv"
}

# Copy a path into the current backup directory and record it in the
# manifest. Files that don't exist yet are recorded as "absent" so rollback
# knows to delete them rather than restore them.
backup_path() {
  local path="$1"
  local destination

  if (( DRY_RUN )); then
    info "DRY-RUN: backup ${path}"
    return
  fi

  destination="${BACKUP_DIR_CURRENT}/files${path}"
  mkdir -p "$(dirname "$destination")"

  if [[ -e "$path" || -L "$path" ]]; then
    cp -aP "$path" "$destination"
    printf 'present\t%s\n' "$path" >> "${BACKUP_DIR_CURRENT}/manifest.tsv"
  else
    printf 'absent\t%s\n' "$path" >> "${BACKUP_DIR_CURRENT}/manifest.tsv"
  fi
}

backup_managed_paths() {
  local path

  backup_path "$SERVICE_FILE"
  backup_path "$VNC_BACKEND_SERVICE_FILE"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    backup_path "$path"
  done < <(wayvnc_config_paths | awk '!seen[$0]++')
  backup_path "$PI_REALVNC_CONFIG_FILE"
  backup_path "$NGINX_SITE"
  backup_path "$NGINX_SITE_LINK"
  backup_path "$AUTH_FILE"
  backup_path "$CERT_FILE"
  backup_path "$KEY_FILE"
  backup_path "$STATE_FILE"
  backup_path "$CERTBOT_RENEW_HOOK"
  backup_path "$CF_CREDENTIALS_FILE"
  backup_path "$CF_AUTH_HOOK"
  backup_path "$CF_CLEANUP_HOOK"
}

backup_auth_path_for_action() {
  prepare_backup_dir
  backup_path "$AUTH_FILE"
}

pi_vnc_config_path() {
  local path="$1"

  case "$path" in
    /etc/wayvnc/config|/root/.config/wayvnc/config|/home/*/.config/wayvnc/config|/root/.vnc/config.d/vncserver-x11)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

restore_pi_vnc_configs_from_backup() {
  local backup_dir="$1"
  local manifest="${backup_dir}/manifest.tsv"
  local status
  local path
  local source_path
  local restored=0

  if [[ -z "$backup_dir" || ! -f "$manifest" ]]; then
    warn "No usable install backup manifest found for Raspberry Pi VNC restore at ${manifest}."
    return 1
  fi

  info "Restoring Raspberry Pi VNC configuration from ${backup_dir}"

  while IFS=$'\t' read -r status path; do
    [[ -z "${status:-}" || -z "${path:-}" ]] && continue
    if ! pi_vnc_config_path "$path"; then
      continue
    fi
    if ! safe_managed_path "$path"; then
      warn "Skipping unexpected Raspberry Pi VNC config backup path ${path}"
      continue
    fi

    restored=1
    case "$status" in
      present)
        source_path="${backup_dir}/files${path}"
        if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
          warn "Backup entry missing for ${path}; skipping."
          continue
        fi
        if (( DRY_RUN )); then
          info "DRY-RUN: restore Raspberry Pi VNC config ${path}"
        else
          remove_path "$path"
          mkdir -p "$(dirname "$path")"
          cp -aP "$source_path" "$path"
        fi
        ;;
      absent)
        remove_path "$path"
        ;;
      *)
        warn "Skipping malformed backup manifest entry for ${path}"
        ;;
    esac
  done < "$manifest"

  if (( ! restored )); then
    warn "Install backup did not contain Raspberry Pi VNC config entries to restore."
  fi
}

# Walk a backup manifest and put every recorded path back the way it was:
# restore "present" entries from the backup copy, delete "absent" ones.
rollback_backup_dir() {
  local backup_dir="$1"
  local manifest="${backup_dir}/manifest.tsv"
  local status
  local path
  local source_path

  if [[ -z "$backup_dir" || ! -f "$manifest" ]]; then
    warn "No usable backup manifest found at ${manifest}."
    return 1
  fi

  info "Restoring files from ${backup_dir}"

  while IFS=$'\t' read -r status path; do
    [[ -z "${status:-}" || -z "${path:-}" ]] && continue
    if ! safe_managed_path "$path"; then
      warn "Skipping unexpected backup path ${path}"
      continue
    fi

    case "$status" in
      present)
        source_path="${backup_dir}/files${path}"
        if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
          warn "Backup entry missing for ${path}; skipping."
          continue
        fi
        remove_path "$path"
        if (( ! DRY_RUN )); then
          mkdir -p "$(dirname "$path")"
          cp -aP "$source_path" "$path"
        fi
        ;;
      absent)
        remove_path "$path"
        ;;
      *)
        warn "Skipping malformed backup manifest entry for ${path}"
        ;;
    esac
  done < "$manifest"
}

latest_backup_dir() {
  local latest=""

  if [[ -d "$BACKUP_ROOT" ]]; then
    latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}' || true)"
  fi

  printf '%s' "$latest"
}

cleanup_empty_managed_dirs() {
  if (( DRY_RUN )); then
    info "DRY-RUN: remove empty managed directories"
    return
  fi

  rmdir "$CERT_DIR" "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null || true
}

remove_acme_webroot() {
  if [[ "$ACME_WEBROOT" != "${STATE_DIR}/acme-webroot" && "$ACME_WEBROOT" != "/var/lib/fast-webvnc/acme-webroot" ]]; then
    warn "Skipping unexpected ACME webroot path during uninstall: ${ACME_WEBROOT}"
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: remove ${ACME_WEBROOT}"
    return
  fi

  if [[ -d "$ACME_WEBROOT" ]]; then
    rm -rf -- "$ACME_WEBROOT"
  fi
}

# Refuse to overwrite a file we didn't create (no state file and no
# "Managed by fast-webvnc" marker) unless the user passed --force.
guard_existing_path() {
  local path="$1"
  local description="$2"

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return
  fi

  if state_exists || managed_file_has_marker "$path"; then
    return
  fi

  if (( FORCE )); then
    warn "${description} already exists at ${path}; --force allows replacing it after backup."
    return
  fi

  die "$EXIT_PRECHECK" "${description} already exists at ${path}, and it was not created by this installer. Re-run with --force only if you want it backed up and replaced."
}

guard_existing_managed_paths() {
  guard_existing_path "$SERVICE_FILE" "Systemd service"
  guard_existing_path "$NGINX_SITE" "Nginx site"
  guard_existing_path "$NGINX_SITE_LINK" "Nginx enabled-site link"
  guard_existing_path "$AUTH_FILE" "HTTP auth file"
  if [[ "$CERT_MODE" == "self-signed" ]]; then
    guard_existing_path "$CERT_FILE" "TLS certificate"
    guard_existing_path "$KEY_FILE" "TLS private key"
  fi
  if is_letsencrypt_mode; then
    guard_existing_path "$CERTBOT_RENEW_HOOK" "Certbot renewal hook"
  fi
}

# ---- src/70-config-generation.sh ----

# 70-config-generation.sh — generates every config file the installer
# manages: the systemd unit, Nginx sites, TLS certificates, Certbot hooks,
# and the Basic Auth htpasswd file.

# Write the websockify systemd unit. The long [Service] block is systemd
# sandboxing: the proxy runs as an unprivileged user with no capabilities
# and a read-only view of the system.
write_service_file() {
  local tmp

  if (( DRY_RUN )); then
    info "DRY-RUN: write ${SERVICE_FILE}"
    return
  fi

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by fast-webvnc. Local changes may be overwritten by install.sh.
[Unit]
Description=Fast WebVNC noVNC WebSocket proxy
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${WEBSOCKIFY_BIN} --idle-timeout 900 --web ${NOVNC_WEB_ROOT} 127.0.0.1:${NOVNC_PORT} ${VNC_HOST}:${VNC_PORT}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

  install -m 0644 "$tmp" "$SERVICE_FILE"
  rm -f "$tmp"
}

prepare_acme_webroot() {
  if [[ "$CERT_MODE" != "letsencrypt" ]]; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: create ACME webroot ${ACME_WEBROOT}"
    return
  fi

  mkdir -p "${ACME_WEBROOT}/.well-known/acme-challenge"
  chown -R root:root "$ACME_WEBROOT"
  find "$ACME_WEBROOT" -type d -exec chmod 0755 {} +
}

# Write a minimal port-80 site that only serves ACME challenges, used to
# pass HTTP-01 validation before the real HTTPS site exists.
write_nginx_acme_site() {
  local tmp

  if [[ "$CERT_MODE" != "letsencrypt" ]]; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: write temporary ACME Nginx site ${NGINX_SITE}"
    return
  fi

  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by fast-webvnc. Local changes may be overwritten by install.sh.
server {
    listen 80;
    server_name ${NGINX_SERVER_NAMES};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 200 "fast-webvnc ACME challenge endpoint\n";
        add_header Content-Type text/plain;
    }
}
EOF

  install -m 0644 "$tmp" "$NGINX_SITE"
  rm -f "$tmp"
  ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
}

# Write the main HTTPS site: TLS hardening, security headers, Basic Auth
# with rate limiting, and proxying to the local noVNC/websockify listener.
# OCSP stapling and HSTS are only enabled for trusted (non-self-signed)
# certificates, where they can actually work.
write_nginx_site() {
  local tmp
  local trusted_tls_extra=""
  local hsts_header=""

  if (( DRY_RUN )); then
    info "DRY-RUN: write ${NGINX_SITE} and enable ${NGINX_SITE_LINK}"
    return
  fi

  if is_trusted_cert_mode; then
    trusted_tls_extra="    ssl_trusted_certificate ${ACTIVE_CERT_FILE};
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 1.0.0.1 valid=300s ipv6=off;
    resolver_timeout 5s;"
    hsts_header='    add_header Strict-Transport-Security "max-age=15552000" always;'
  fi

  tmp="$(mktemp)"
  {
    cat <<EOF
# Managed by fast-webvnc. Local changes may be overwritten by install.sh.
map \$http_upgrade \$fast_webvnc_connection_upgrade {
    default upgrade;
    '' close;
}

limit_req_zone \$binary_remote_addr zone=fast_webvnc_auth:10m rate=30r/m;

EOF

    if [[ "$CERT_MODE" == "letsencrypt" ]]; then
      cat <<EOF
server {
    listen 80;
    server_name ${NGINX_SERVER_NAMES};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 ${HTTP_REDIRECT_TARGET};
    }
}

EOF
    fi

    cat <<EOF
server {
    listen ${HTTPS_PORT} ssl http2;
    server_name ${NGINX_SERVER_NAMES};

    ssl_certificate ${ACTIVE_CERT_FILE};
    ssl_certificate_key ${ACTIVE_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
    ssl_prefer_server_ciphers off;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_session_cache shared:fast_webvnc_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
${trusted_tls_extra}

${hsts_header}
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    # noVNC currently uses inline/eval-style browser code paths in bundled assets.
    # Keep this scoped to the authenticated noVNC origin and revisit when noVNC supports a stricter CSP.
    add_header Content-Security-Policy "default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'" always;

    limit_req_status 429;
    auth_basic "Fast WebVNC";
    auth_basic_user_file ${AUTH_FILE};

    location = / {
        limit_req zone=fast_webvnc_auth burst=20 nodelay;
        return 302 /vnc.html?resize=scale&path=websockify;
    }

    location = /vnc.html {
        limit_req zone=fast_webvnc_auth burst=20 nodelay;
        proxy_pass http://127.0.0.1:${NOVNC_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    location /websockify {
        proxy_pass http://127.0.0.1:${NOVNC_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$fast_webvnc_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    location / {
        proxy_pass http://127.0.0.1:${NOVNC_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }
}
EOF
  } > "$tmp"

  install -m 0644 "$tmp" "$NGINX_SITE"
  rm -f "$tmp"
  ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
}

generate_self_signed_cert() {
  local cert_cn="$HOSTNAME_VALUE"

  if (( DRY_RUN )); then
    info "DRY-RUN: generate ECDSA P-256 self-signed certificate ${CERT_FILE} with SAN ${SAN_LIST}"
    return
  fi

  mkdir -p "$CERT_DIR"

  openssl req -x509 -nodes -days 825 \
    -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=${cert_cn}" \
    -addext "subjectAltName=${SAN_LIST}"

  chown root:root "$KEY_FILE" "$CERT_FILE"
  chmod 0600 "$KEY_FILE"
  chmod 0644 "$CERT_FILE"
}

# Generate Certbot DNS-01 hook scripts for Cloudflare: the auth hook creates
# the _acme-challenge TXT record via the Cloudflare API, the cleanup hook
# deletes it. The API token is stored in a root-only credentials file.
write_cloudflare_hooks() {
  if [[ "$CERT_MODE" != "letsencrypt-dns" || -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" ]]; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: write Cloudflare credentials ${CF_CREDENTIALS_FILE}"
    info "DRY-RUN: write Cloudflare DNS-01 auth hook ${CF_AUTH_HOOK}"
    info "DRY-RUN: write Cloudflare DNS-01 cleanup hook ${CF_CLEANUP_HOOK}"
    DNS_AUTH_HOOK="$CF_AUTH_HOOK"
    DNS_CLEANUP_HOOK="$CF_CLEANUP_HOOK"
    return
  fi

  mkdir -p "$CONFIG_DIR"

  local tmp_creds
  tmp_creds="$(mktemp)"
  printf 'CF_API_TOKEN=%s\nCF_ZONE_ID=%s\n' "$CF_API_TOKEN" "$CF_ZONE_ID" > "$tmp_creds"
  install -m 0600 "$tmp_creds" "$CF_CREDENTIALS_FILE"
  rm -f "$tmp_creds"

  cat > "$CF_AUTH_HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Cloudflare DNS-01 auth hook — generated by fast-webvnc installer
set -Eeuo pipefail
# shellcheck source=/dev/null
source /etc/fast-webvnc/cf-credentials
# Pass the bearer token via a 0600 header file so it never appears in argv/ps.
auth_header_file="$(mktemp)"
trap 'rm -f "$auth_header_file"' EXIT
printf 'Authorization: Bearer %s\n' "${CF_API_TOKEN}" > "$auth_header_file"
curl -sf -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
  -H @"$auth_header_file" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"TXT\",\"name\":\"_acme-challenge.${CERTBOT_DOMAIN}\",\"content\":\"${CERTBOT_VALIDATION}\",\"ttl\":60}" \
  >/dev/null
sleep 30
HOOK_EOF
  chmod 0755 "$CF_AUTH_HOOK"

  cat > "$CF_CLEANUP_HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Cloudflare DNS-01 cleanup hook — generated by fast-webvnc installer
set -Eeuo pipefail
# shellcheck source=/dev/null
source /etc/fast-webvnc/cf-credentials
# Pass the bearer token via a 0600 header file so it never appears in argv/ps.
auth_header_file="$(mktemp)"
trap 'rm -f "$auth_header_file"' EXIT
printf 'Authorization: Bearer %s\n' "${CF_API_TOKEN}" > "$auth_header_file"
record_id="$(curl -sf \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=_acme-challenge.${CERTBOT_DOMAIN}&content=${CERTBOT_VALIDATION}" \
  -H @"$auth_header_file" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"]) if r else ""')"
[[ -n "$record_id" ]] && curl -sf -X DELETE \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
  -H @"$auth_header_file" >/dev/null || true
HOOK_EOF
  chmod 0755 "$CF_CLEANUP_HOOK"

  DNS_AUTH_HOOK="$CF_AUTH_HOOK"
  DNS_CLEANUP_HOOK="$CF_CLEANUP_HOOK"

  info "Wrote Cloudflare DNS-01 hooks to ${CONFIG_DIR}"
}

obtain_letsencrypt_certificate() {
  local -a certbot_args=()

  if ! is_letsencrypt_mode; then
    return
  fi

  if (( DRY_RUN )); then
    if [[ "$CERT_MODE" == "letsencrypt-dns" ]]; then
      info "DRY-RUN: certbot certonly --manual --preferred-challenges dns --manual-auth-hook ${DNS_AUTH_HOOK} -d ${HOSTNAME_VALUE} --cert-name ${LE_CERT_NAME}"
    else
      info "DRY-RUN: certbot certonly --webroot -w ${ACME_WEBROOT} -d ${HOSTNAME_VALUE} --cert-name ${LE_CERT_NAME}"
    fi
    if [[ "$CERT_STAGING" == "1" ]]; then
      info "DRY-RUN: use Let's Encrypt staging"
    fi
    info "DRY-RUN: $(dns01_guidance)"
    return
  fi

  info "Requesting Let's Encrypt certificate for ${HOSTNAME_VALUE}"
  info "$(dns01_guidance)"

  certbot_args=(
    certonly
    -d "$HOSTNAME_VALUE"
    --cert-name "$LE_CERT_NAME"
    --email "$LE_EMAIL"
    --agree-tos
    --no-eff-email
    --non-interactive
    --keep-until-expiring
  )

  if [[ "$CERT_STAGING" == "1" ]]; then
    certbot_args+=(--staging)
  fi

  if [[ "$CERT_MODE" == "letsencrypt-dns" ]]; then
    certbot_args+=(
      --manual
      --preferred-challenges dns
      --manual-auth-hook "$DNS_AUTH_HOOK"
      --manual-public-ip-logging-ok
    )
    if [[ -n "$DNS_CLEANUP_HOOK" ]]; then
      certbot_args+=(--manual-cleanup-hook "$DNS_CLEANUP_HOOK")
    fi
  else
    certbot_args+=(--webroot -w "$ACME_WEBROOT")
  fi

  certbot "${certbot_args[@]}"

  if [[ ! -f "$ACTIVE_CERT_FILE" || ! -f "$ACTIVE_KEY_FILE" ]]; then
    die "$EXIT_PRECHECK" "Certbot completed, but expected certificate files were not found under /etc/letsencrypt/live/${LE_CERT_NAME}."
  fi
}

write_certbot_renewal_hook() {
  local tmp

  if ! is_letsencrypt_mode; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: write Certbot deploy hook ${CERTBOT_RENEW_HOOK}"
    return
  fi

  mkdir -p "$(dirname "$CERTBOT_RENEW_HOOK")"
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env sh
# Managed by fast-webvnc. Reload Nginx after Certbot renews certificates.
if command -v systemctl >/dev/null 2>&1; then
  systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
fi
EOF
  install -m 0755 "$tmp" "$CERTBOT_RENEW_HOOK"
  rm -f "$tmp"
}

# Before asking Let's Encrypt to validate, serve a test token through our own
# Nginx site and fetch it locally. This catches server_name conflicts and
# routing mistakes without burning an ACME validation attempt.
verify_local_acme_challenge_route() {
  local token_path="${ACME_WEBROOT}/.well-known/acme-challenge/fast-webvnc-local-check"
  local token_value="fast-webvnc-acme-ok"
  local url="http://${HOSTNAME_VALUE}/.well-known/acme-challenge/fast-webvnc-local-check"
  local body=""

  if [[ "$CERT_MODE" != "letsencrypt" ]]; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: verify local ACME challenge route ${url}"
    return
  fi

  printf '%s\n' "$token_value" > "$token_path"
  body="$(curl -sS --noproxy '*' --max-time 5 --resolve "${HOSTNAME_VALUE}:80:127.0.0.1" "$url" 2>/dev/null || true)"
  rm -f "$token_path"

  if [[ "$body" != "$token_value" ]]; then
    die "$EXIT_PRECHECK" "Nginx did not serve the local ACME HTTP-01 challenge test for ${HOSTNAME_VALUE}. Check Nginx server_name conflicts before retrying, or use DNS-01 instead. $(dns01_guidance)"
  fi
}

enable_certbot_timer_if_available() {
  if ! is_letsencrypt_mode; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: enable certbot.timer when available"
    return
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || warn "Could not enable certbot.timer; Certbot may still be renewed by cron depending on the package."
  fi
}

apply_auth_file_permissions() {
  if getent group www-data >/dev/null 2>&1; then
    chown root:www-data "$AUTH_FILE"
    chmod 0640 "$AUTH_FILE"
  else
    chown root:root "$AUTH_FILE"
    chmod 0600 "$AUTH_FILE"
  fi
}

auth_user_count() {
  if [[ ! -f "$AUTH_FILE" ]]; then
    printf '0'
    return
  fi

  awk -F: 'NF >= 2 {count++} END {print count + 0}' "$AUTH_FILE"
}

create_or_update_auth_user() {
  local create_flag=()

  if (( DRY_RUN )); then
    info "DRY-RUN: create/update HTTP Basic Auth user ${WEB_USER} in ${AUTH_FILE}"
    return
  fi

  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$AUTH_FILE" ]]; then
    create_flag=(-c)
  fi

  if ! printf '%s\n' "$WEB_PASSWORD" | htpasswd -B -i "${create_flag[@]}" "$AUTH_FILE" "$WEB_USER" >/dev/null; then
    die "$EXIT_PRECHECK" "htpasswd bcrypt update failed. Refusing to fall back to weaker hash formats."
  fi

  apply_auth_file_permissions
}

write_auth_file() {
  create_or_update_auth_user
}

# ---- src/80-state-verify-helpers.sh ----

# 80-state-verify-helpers.sh — the install state file (what verify, rollback,
# and uninstall rely on) plus the individual checks run by the verify action.

state_write_line() {
  local key="$1"
  local value="$2"
  # %q shell-quotes the value, so the state file is safe to source later.
  printf '%s=%q\n' "$key" "$value"
}

write_state_file() {
  local tmp
  local installed_at

  if (( DRY_RUN )); then
    info "DRY-RUN: write state ${STATE_FILE}"
    return
  fi

  installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp)"
  {
    echo "# Managed by fast-webvnc. Used for verify, rollback, and uninstall."
    state_write_line FAST_WEBVNC_VERSION "$VERSION"
    state_write_line INSTALLED_AT "$installed_at"
    state_write_line SERVICE_NAME "$SERVICE_NAME"
    state_write_line SERVICE_FILE "$SERVICE_FILE"
    state_write_line VNC_BACKEND_SERVICE_NAME "$VNC_BACKEND_SERVICE_NAME"
    state_write_line VNC_BACKEND_SERVICE_FILE "$VNC_BACKEND_SERVICE_FILE"
    state_write_line VNC_BACKEND_MANAGED "$VNC_BACKEND_MANAGED"
    state_write_line PI_VNC_AUTOMANAGED "$PI_VNC_AUTOMANAGED"
    state_write_line PI_WAYVNC_CONFIG_FILE "$PI_WAYVNC_CONFIG_FILE"
    state_write_line PI_REALVNC_CONFIG_FILE "$PI_REALVNC_CONFIG_FILE"
    state_write_line NGINX_SITE "$NGINX_SITE"
    state_write_line NGINX_SITE_LINK "$NGINX_SITE_LINK"
    state_write_line CONFIG_DIR "$CONFIG_DIR"
    state_write_line CERT_DIR "$CERT_DIR"
    state_write_line CERT_FILE "$CERT_FILE"
    state_write_line KEY_FILE "$KEY_FILE"
    state_write_line AUTH_FILE "$AUTH_FILE"
    state_write_line WEB_USER "$WEB_USER"
    state_write_line SERVICE_USER "$SERVICE_USER"
    state_write_line SERVICE_USER_CREATED "$SERVICE_USER_CREATED"
    state_write_line WEBSOCKIFY_BIN "$WEBSOCKIFY_BIN"
    state_write_line VNC_HOST "$VNC_HOST"
    state_write_line VNC_PORT "$VNC_PORT"
    state_write_line NOVNC_PORT "$NOVNC_PORT"
    state_write_line HTTPS_PORT "$HTTPS_PORT"
    state_write_line HOSTNAME_VALUE "$HOSTNAME_VALUE"
    state_write_line CERT_MODE "$CERT_MODE"
    state_write_line NOVNC_WEB_ROOT "$NOVNC_WEB_ROOT"
    state_write_line NGINX_SERVER_NAMES "$NGINX_SERVER_NAMES"
    state_write_line ENDPOINT_URL "$ENDPOINT_URL"
    state_write_line ACTIVE_CERT_FILE "$ACTIVE_CERT_FILE"
    state_write_line ACTIVE_KEY_FILE "$ACTIVE_KEY_FILE"
    state_write_line ACME_WEBROOT "$ACME_WEBROOT"
    state_write_line CERTBOT_RENEW_HOOK "$CERTBOT_RENEW_HOOK"
    state_write_line LE_CERT_NAME "$LE_CERT_NAME"
    state_write_line LE_EMAIL "$LE_EMAIL"
    state_write_line CERT_STAGING "$CERT_STAGING"
    state_write_line DNS_AUTH_HOOK "$DNS_AUTH_HOOK"
    state_write_line DNS_CLEANUP_HOOK "$DNS_CLEANUP_HOOK"
    state_write_line PROVIDED_CERT_FILE "$PROVIDED_CERT_FILE"
    state_write_line PROVIDED_KEY_FILE "$PROVIDED_KEY_FILE"
    state_write_line LAST_BACKUP_DIR "$BACKUP_DIR_CURRENT"
  } > "$tmp"

  install -m 0600 "$tmp" "$STATE_FILE"
  rm -f "$tmp"
}

# Load the state file from a previous install. The fallback defaults below
# keep newer installers compatible with state written by older versions.
load_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    return 1
  fi

  # shellcheck source=/dev/null
  source "$STATE_FILE"
  if [[ -n "${FAST_WEBVNC_VERSION:-}" && "${FAST_WEBVNC_VERSION%%.*}" != "${VERSION%%.*}" ]]; then
    warn "State file version ${FAST_WEBVNC_VERSION} differs from installer version ${VERSION}; continuing with compatibility defaults."
  fi
  ACTIVE_CERT_FILE="${ACTIVE_CERT_FILE:-$CERT_FILE}"
  ACTIVE_KEY_FILE="${ACTIVE_KEY_FILE:-$KEY_FILE}"
  ACME_WEBROOT="${ACME_WEBROOT:-${STATE_DIR}/acme-webroot}"
  CERTBOT_RENEW_HOOK="${CERTBOT_RENEW_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/fast-webvnc-reload-nginx}"
  LE_CERT_NAME="${LE_CERT_NAME:-}"
  LE_EMAIL="${LE_EMAIL:-}"
  SERVICE_USER_CREATED="${SERVICE_USER_CREATED:-0}"
  VNC_BACKEND_SERVICE_NAME="${VNC_BACKEND_SERVICE_NAME:-fast-webvnc-x11vnc.service}"
  VNC_BACKEND_SERVICE_FILE="${VNC_BACKEND_SERVICE_FILE:-/etc/systemd/system/${VNC_BACKEND_SERVICE_NAME}}"
  VNC_BACKEND_MANAGED="${VNC_BACKEND_MANAGED:-0}"
  PI_VNC_AUTOMANAGED="${PI_VNC_AUTOMANAGED:-0}"
  PI_WAYVNC_CONFIG_FILE="${PI_WAYVNC_CONFIG_FILE:-/etc/wayvnc/config}"
  PI_REALVNC_CONFIG_FILE="${PI_REALVNC_CONFIG_FILE:-/root/.vnc/config.d/vncserver-x11}"
  WEBSOCKIFY_BIN="${WEBSOCKIFY_BIN:-/usr/bin/websockify}"
  CERT_STAGING="${CERT_STAGING:-0}"
  DNS_AUTH_HOOK="${DNS_AUTH_HOOK:-}"
  DNS_CLEANUP_HOOK="${DNS_CLEANUP_HOOK:-}"
  PROVIDED_CERT_FILE="${PROVIDED_CERT_FILE:-}"
  PROVIDED_KEY_FILE="${PROVIDED_KEY_FILE:-}"
  return 0
}

systemd_reload_enable_restart() {
  run systemctl daemon-reload
  run systemctl enable "$SERVICE_NAME"
  run systemctl restart "$SERVICE_NAME"
}

nginx_validate_enable_restart() {
  run nginx -t
  run systemctl enable nginx
  run systemctl restart nginx
}

service_is_active() {
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

nginx_is_active() {
  systemctl is-active --quiet nginx 2>/dev/null
}

check_file_exists() {
  local path="$1"
  local label="$2"

  if [[ -e "$path" || -L "$path" ]]; then
    info "OK: ${label} exists (${path})"
    return 0
  fi

  error "FAIL: ${label} missing (${path})"
  return 1
}

check_auth_permissions() {
  local mode
  local other_digit

  if [[ ! -f "$AUTH_FILE" ]]; then
    error "FAIL: auth file missing (${AUTH_FILE})"
    return 1
  fi

  mode="$(stat -c '%a' "$AUTH_FILE" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    error "FAIL: could not stat auth file ${AUTH_FILE}"
    return 1
  fi

  other_digit="${mode: -1}"
  if (( other_digit != 0 )); then
    error "FAIL: auth file ${AUTH_FILE} is world-readable or world-accessible (mode ${mode})"
    return 1
  fi

  info "OK: auth file permissions are mode ${mode}"
}

check_key_permissions() {
  local mode
  local group_digit
  local other_digit

  if [[ ! -f "$ACTIVE_KEY_FILE" ]]; then
    error "FAIL: TLS key missing (${ACTIVE_KEY_FILE})"
    return 1
  fi

  mode="$(stat -Lc '%a' "$ACTIVE_KEY_FILE" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    error "FAIL: could not stat TLS key ${ACTIVE_KEY_FILE}"
    return 1
  fi

  group_digit="${mode: -2:1}"
  other_digit="${mode: -1}"
  if (( group_digit != 0 || other_digit != 0 )); then
    error "FAIL: TLS key ${ACTIVE_KEY_FILE} should not be group/world-accessible (mode ${mode})"
    return 1
  fi

  info "OK: TLS key permissions are mode ${mode}"
}

check_certificate_validity() {
  if [[ ! -f "$ACTIVE_CERT_FILE" ]]; then
    error "FAIL: TLS certificate missing (${ACTIVE_CERT_FILE})"
    return 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    error "FAIL: openssl is unavailable; cannot verify certificate validity"
    return 1
  fi

  if openssl x509 -checkend 86400 -noout -in "$ACTIVE_CERT_FILE" >/dev/null 2>&1; then
    info "OK: TLS certificate is present and not expiring within 24 hours"
    return 0
  fi

  error "FAIL: TLS certificate is expired or expires within 24 hours (${ACTIVE_CERT_FILE})"
  return 1
}

check_novnc_listener() {
  local listeners

  if ! command -v ss >/dev/null 2>&1; then
    error "FAIL: ss is unavailable; cannot verify noVNC listener"
    return 1
  fi

  listeners="$(list_listeners_on_port "$NOVNC_PORT" || true)"
  if grep -Eq "(127\.0\.0\.1|\[::1\]):${NOVNC_PORT}$" <<<"$listeners"; then
    info "OK: noVNC is listening on localhost:${NOVNC_PORT}"
    return 0
  fi

  error "FAIL: noVNC is not listening on 127.0.0.1:${NOVNC_PORT}"
  return 1
}

# Hit the public HTTPS endpoint. Any of 401 (auth prompt), 302 (redirect to
# vnc.html), or 200 means Nginx, TLS, and the proxy chain are all working.
curl_https_check() {
  local url
  local code
  local host="$HOSTNAME_VALUE"
  local -a curl_args=()

  if ! command -v curl >/dev/null 2>&1; then
    error "FAIL: curl is unavailable; cannot verify HTTPS endpoint"
    return 1
  fi

  url="$(format_url "$host" "$HTTPS_PORT")"
  curl_args=(-sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 8)

  if is_trusted_cert_mode; then
    code="$(curl "${curl_args[@]}" "$url" 2>/dev/null || true)"
  elif is_ipv4 "$host"; then
    code="$(curl -k "${curl_args[@]}" "$url" 2>/dev/null || true)"
  else
    code="$(curl -k "${curl_args[@]}" --resolve "${host}:${HTTPS_PORT}:127.0.0.1" "$url" 2>/dev/null || true)"
  fi

  if [[ "$code" == "401" || "$code" == "302" || "$code" == "200" ]]; then
    info "OK: HTTPS endpoint responded with HTTP ${code}"
    return 0
  fi

  error "FAIL: HTTPS endpoint check for ${url} returned HTTP ${code:-none}"
  return 1
}

check_novnc_asset() {
  local code

  if ! command -v curl >/dev/null 2>&1; then
    error "FAIL: curl is unavailable; cannot verify noVNC asset path"
    return 1
  fi

  code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NOVNC_PORT}/vnc.html" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    info "OK: noVNC /vnc.html is served locally"
    return 0
  fi

  error "FAIL: noVNC /vnc.html returned HTTP ${code:-none}"
  return 1
}

check_websocket_upgrade() {
  local headers

  if ! command -v curl >/dev/null 2>&1; then
    error "FAIL: curl is unavailable; cannot verify WebSocket upgrade"
    return 1
  fi

  headers="$(curl -sS --noproxy '*' --http1.1 --max-time 5 -D - -o /dev/null \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: ZmFzdHdlYnZuY3Rlc3QxMg==' \
    "http://127.0.0.1:${NOVNC_PORT}/websockify" 2>/dev/null || true)"

  if grep -q '^HTTP/.* 101 ' <<<"$headers"; then
    info "OK: noVNC WebSocket upgrade succeeds locally"
    return 0
  fi

  error "FAIL: noVNC WebSocket upgrade did not return HTTP 101"
  return 1
}

# ---- src/90-actions-main.sh ----

# 90-actions-main.sh — the top-level actions (install, verify, status,
# rollback, uninstall, user management, logs) and the main() dispatcher.

verify_installation() {
  local failures=0

  if (( DRY_RUN )); then
    info "DRY-RUN: verify would check service, Nginx, files, HTTPS endpoint, and VNC backend."
    return 0
  fi

  if ! load_state; then
    error "FAIL: state file missing (${STATE_FILE})"
    return "$EXIT_VERIFY"
  fi

  info "Verifying fast-webvnc installation"

  check_file_exists "$SERVICE_FILE" "systemd service" || failures=$((failures + 1))
  check_file_exists "$NGINX_SITE" "Nginx site" || failures=$((failures + 1))
  check_file_exists "$NGINX_SITE_LINK" "Nginx enabled-site link" || failures=$((failures + 1))
  check_certificate_validity || failures=$((failures + 1))
  check_key_permissions || failures=$((failures + 1))
  check_auth_permissions || failures=$((failures + 1))

  if [[ "${CERT_MODE:-}" == "letsencrypt" ]]; then
    check_file_exists "$CERTBOT_RENEW_HOOK" "Certbot renewal hook" || failures=$((failures + 1))
    if [[ -d "$ACME_WEBROOT" ]]; then
      info "OK: ACME webroot exists (${ACME_WEBROOT})"
    else
      error "FAIL: ACME webroot missing (${ACME_WEBROOT})"
      failures=$((failures + 1))
    fi
  fi

  if service_is_active; then
    info "OK: ${SERVICE_NAME} is active"
  else
    error "FAIL: ${SERVICE_NAME} is not active"
    failures=$((failures + 1))
  fi

  if nginx_is_active; then
    info "OK: nginx is active"
  else
    error "FAIL: nginx is not active"
    failures=$((failures + 1))
  fi

  if nginx -t >/dev/null 2>&1; then
    info "OK: nginx configuration validates"
  else
    error "FAIL: nginx configuration does not validate"
    failures=$((failures + 1))
  fi

  check_novnc_listener || failures=$((failures + 1))
  check_novnc_asset || failures=$((failures + 1))
  check_websocket_upgrade || failures=$((failures + 1))

  if vnc_protocol_responds "$VNC_HOST" "$VNC_PORT"; then
    info "OK: VNC backend speaks RFB at ${VNC_HOST}:${VNC_PORT}"
  else
    error "FAIL: VNC backend does not speak RFB at ${VNC_HOST}:${VNC_PORT}"
    failures=$((failures + 1))
  fi

  curl_https_check || failures=$((failures + 1))

  if (( failures > 0 )); then
    error "Verification failed with ${failures} issue(s)."
    return "$EXIT_VERIFY"
  fi

  info "Verification passed."
}

print_endpoint_summary() {
  local ip
  local -a ips=()

  info "Endpoint: ${ENDPOINT_URL}"
  if is_letsencrypt_mode; then
    info "Let's Encrypt certificates are valid for ${HOSTNAME_VALUE}; use the DNS endpoint above."
    info "$(dns01_guidance)"
  elif [[ "$CERT_MODE" == "provided" ]]; then
    info "Using provided TLS certificate ${ACTIVE_CERT_FILE}."
  else
    mapfile -t ips < <(detect_lan_ips)
    for ip in "${ips[@]}"; do
      info "LAN URL: $(format_url "$ip" "$HTTPS_PORT")"
    done
    info "Self-signed certificate warnings are expected unless you install a trusted certificate."
  fi
  info "HTTPS username: ${WEB_USER}"
}

# The install flow, in order: validate inputs, check the system, back up
# everything we are about to touch, set up the VNC backend, write configs
# and certificates, start services, and verify the result. Once the backup
# exists (INSTALL_STARTED=1), any failure triggers an automatic rollback via
# the ERR trap in 10-core.sh.
install_action() {
  CURRENT_ACTION="install"

  require_root
  collect_install_inputs
  validate_install_options
  validate_letsencrypt_options
  validate_provided_cert_options
  build_runtime_names
  if (( ! AUTO_VNC_BACKEND )); then
    ensure_vnc_backend
  fi
  preflight_base
  check_port_conflicts
  install_packages
  ensure_post_package_commands
  detect_novnc_web_root
  if (( ! AUTO_VNC_BACKEND )); then
    require_vnc_loopback_only
  fi
  warn_if_letsencrypt_dns_unresolved
  guard_existing_managed_paths

  prepare_backup_dir
  backup_managed_paths
  INSTALL_STARTED=1

  if (( AUTO_VNC_BACKEND )); then
    ensure_vnc_backend
  fi
  detect_vnc_provider
  warn_if_vnc_exposed
  ensure_service_user

  write_cloudflare_hooks
  validate_dns01_hooks

  info "Writing fast-webvnc configuration"
  write_service_file
  write_auth_file

  if is_letsencrypt_mode; then
    prepare_acme_webroot
    if [[ "$CERT_MODE" == "letsencrypt" ]]; then
      write_nginx_acme_site
      nginx_validate_enable_restart
      verify_local_acme_challenge_route
    fi
    obtain_letsencrypt_certificate
    write_certbot_renewal_hook
    enable_certbot_timer_if_available
  elif [[ "$CERT_MODE" == "self-signed" ]]; then
    generate_self_signed_cert
  fi

  write_nginx_site

  info "Starting services"
  systemd_reload_enable_restart
  nginx_validate_enable_restart
  write_state_file

  verify_installation
  print_endpoint_summary
}

status_action() {
  local active="unknown"
  local enabled="unknown"
  local nginx_active="unknown"

  if load_state; then
    info "Installed: yes"
    info "Installed at: ${INSTALLED_AT:-unknown}"
    info "Endpoint: ${ENDPOINT_URL:-$(format_url "${HOSTNAME_VALUE:-localhost}" "${HTTPS_PORT:-443}")}"
    info "VNC backend: ${VNC_HOST:-unknown}:${VNC_PORT:-unknown}"
    info "noVNC listener: 127.0.0.1:${NOVNC_PORT:-unknown}"
    info "HTTPS user: ${WEB_USER:-unknown}"
    info "Service user: ${SERVICE_USER:-unknown}"
    info "Certificate mode: ${CERT_MODE:-unknown}"
    info "Certificate file: ${ACTIVE_CERT_FILE:-unknown}"
    info "Last backup: ${LAST_BACKUP_DIR:-unknown}"
  else
    info "Installed: no state file found at ${STATE_FILE}"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    nginx_active="$(systemctl is-active nginx 2>/dev/null || true)"
  fi

  info "${SERVICE_NAME}: active=${active}, enabled=${enabled}"
  info "nginx: active=${nginx_active}"
}

auth_password_action() {
  local verb="$1"

  CURRENT_ACTION="$verb"
  require_root
  detect_apt
  require_command htpasswd "Install the apache2-utils package."
  prompt_username_if_needed
  validate_web_user

  if [[ -z "$WEB_PASSWORD" ]]; then
    if (( NON_INTERACTIVE )); then
      die "$EXIT_USAGE" "--non-interactive requires --password or FAST_WEBVNC_PASSWORD for ${verb}."
    fi
    prompt_password
  fi
  validate_web_password

  backup_auth_path_for_action
  create_or_update_auth_user
  info "Updated HTTPS Basic Auth user ${WEB_USER}."
}

remove_user_action() {
  local count

  CURRENT_ACTION="remove-user"
  require_root
  require_command htpasswd "Install the apache2-utils package."
  prompt_username_if_needed
  validate_web_user

  if [[ ! -f "$AUTH_FILE" ]]; then
    die "$EXIT_PRECHECK" "Auth file does not exist: ${AUTH_FILE}"
  fi

  count="$(auth_user_count)"
  if (( count <= 1 && ! FORCE )); then
    die "$EXIT_PRECHECK" "Refusing to remove the last HTTPS auth user. Re-run with --force if you intentionally want an empty auth file."
  fi

  if (( DRY_RUN )); then
    backup_auth_path_for_action
    info "DRY-RUN: remove HTTP Basic Auth user ${WEB_USER} from ${AUTH_FILE}"
    return
  fi

  backup_auth_path_for_action
  htpasswd -D "$AUTH_FILE" "$WEB_USER" >/dev/null
  apply_auth_file_permissions
  info "Removed HTTPS Basic Auth user ${WEB_USER}."
}

logs_action() {
  CURRENT_ACTION="logs"

  if (( DRY_RUN )); then
    info "DRY-RUN: journalctl -u ${SERVICE_NAME} -u nginx -n 200 --no-pager"
    return
  fi

  require_command journalctl "Install systemd-journald tools."
  journalctl -u "$SERVICE_NAME" -u nginx -n 200 --no-pager
}

stop_disable_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      info "DRY-RUN: systemctl stop ${SERVICE_NAME}"
      info "DRY-RUN: systemctl disable ${SERVICE_NAME}"
    else
      systemctl stop "$SERVICE_NAME" 2>/dev/null || true
      systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi
    run systemctl daemon-reload
  fi
}

stop_disable_vnc_backend_if_managed() {
  if [[ "${VNC_BACKEND_MANAGED:-0}" != "1" && ! -e "$VNC_BACKEND_SERVICE_FILE" && ! -L "$VNC_BACKEND_SERVICE_FILE" ]]; then
    return
  fi

  if [[ "${VNC_BACKEND_MANAGED:-0}" != "1" ]] && ! managed_file_has_marker "$VNC_BACKEND_SERVICE_FILE"; then
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      info "DRY-RUN: systemctl stop ${VNC_BACKEND_SERVICE_NAME}"
      info "DRY-RUN: systemctl disable ${VNC_BACKEND_SERVICE_NAME}"
    else
      systemctl stop "$VNC_BACKEND_SERVICE_NAME" 2>/dev/null || true
      systemctl disable "$VNC_BACKEND_SERVICE_NAME" 2>/dev/null || true
    fi
    run systemctl daemon-reload
  fi
}

restart_nginx_if_available() {
  if command -v nginx >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      info "DRY-RUN: nginx -t && systemctl restart nginx"
      return
    fi

    nginx -t
    systemctl restart nginx
  fi
}

restart_restored_service_if_present() {
  if managed_file_has_marker "$VNC_BACKEND_SERVICE_FILE"; then
    run systemctl daemon-reload
    run systemctl enable "$VNC_BACKEND_SERVICE_NAME"
    run systemctl restart "$VNC_BACKEND_SERVICE_NAME"
  fi
  if [[ ! -f "$SERVICE_FILE" ]] || ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: systemctl enable --now ${SERVICE_NAME}"
    return
  fi

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
}

rollback_action() {
  local backup_dir=""

  CURRENT_ACTION="rollback"
  require_root

  if load_state && [[ -n "${LAST_BACKUP_DIR:-}" ]]; then
    backup_dir="$LAST_BACKUP_DIR"
  else
    backup_dir="$(latest_backup_dir)"
  fi

  if [[ -z "$backup_dir" ]]; then
    die "$EXIT_ROLLBACK" "No fast-webvnc backup was found under ${BACKUP_ROOT}."
  fi

  info "Rolling back using ${backup_dir}"
  stop_disable_service
  stop_disable_vnc_backend_if_managed
  ROLLBACK_IN_PROGRESS=1
  rollback_backup_dir "$backup_dir"
  restart_restored_service_if_present
  restart_nginx_if_available
  cleanup_empty_managed_dirs
  info "Rollback complete."
}

remove_managed_files_for_uninstall() {
  remove_path "$SERVICE_FILE"
  if [[ "${VNC_BACKEND_MANAGED:-0}" == "1" ]] || managed_file_has_marker "$VNC_BACKEND_SERVICE_FILE"; then
    remove_path "$VNC_BACKEND_SERVICE_FILE"
  fi
  remove_path "$NGINX_SITE_LINK"
  remove_path "$NGINX_SITE"
  remove_path "$AUTH_FILE"
  remove_path "$CERT_FILE"
  remove_path "$KEY_FILE"
  remove_path "$CERTBOT_RENEW_HOOK"
  remove_path "$CF_CREDENTIALS_FILE"
  remove_path "$CF_AUTH_HOOK"
  remove_path "$CF_CLEANUP_HOOK"
  remove_acme_webroot
  remove_path "$STATE_FILE"
  cleanup_empty_managed_dirs
}

remove_service_user_if_created() {
  if [[ "${SERVICE_USER_CREATED:-0}" != "1" || -z "${SERVICE_USER:-}" ]]; then
    return
  fi

  if (( DRY_RUN )); then
    info "DRY-RUN: remove installer-created system user ${SERVICE_USER}"
    return
  fi

  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then
      userdel "$SERVICE_USER" || warn "Could not remove installer-created user ${SERVICE_USER}; remove it manually if no longer needed."
    else
      warn "userdel is unavailable; installer-created user ${SERVICE_USER} was left in place."
    fi
  fi
}

# Remove everything the installer manages. Raspberry Pi VNC configs are
# restored from the backup taken at install time; if the installer was the
# one that enabled Pi VNC, it is stopped and disabled too.
uninstall_action() {
  local install_backup_dir=""

  CURRENT_ACTION="uninstall"
  require_root

  if state_exists; then
    load_state || true
    install_backup_dir="${LAST_BACKUP_DIR:-}"
  elif (( ! FORCE )); then
    die "$EXIT_PRECHECK" "No state file found at ${STATE_FILE}. Re-run uninstall with --force only if you want to remove known fast-webvnc paths anyway."
  fi

  guard_existing_managed_paths
  prepare_backup_dir
  backup_managed_paths

  info "Stopping fast-webvnc and removing managed files"
  stop_disable_service
  stop_disable_vnc_backend_if_managed
  if [[ -n "$install_backup_dir" ]]; then
    if [[ "${PI_VNC_AUTOMANAGED:-0}" == "1" ]]; then
      disable_pi_vnc_units
      restore_pi_vnc_configs_from_backup "$install_backup_dir" || true
    else
      restore_pi_vnc_configs_from_backup "$install_backup_dir" || true
      restart_active_pi_vnc_units
    fi
  fi
  remove_managed_files_for_uninstall
  remove_service_user_if_created
  restart_nginx_if_available
  info "Uninstall complete. Backups were left under ${BACKUP_ROOT}."
}

main() {
  parse_args "$@"

  case "$ACTION" in
    help)
      show_help
      ;;
    install)
      install_action
      ;;
    verify)
      CURRENT_ACTION="verify"
      require_root
      verify_installation
      ;;
    status)
      CURRENT_ACTION="status"
      status_action
      ;;
    rollback)
      rollback_action
      ;;
    uninstall)
      uninstall_action
      ;;
    add-user)
      auth_password_action "add-user"
      ;;
    set-password)
      auth_password_action "set-password"
      ;;
    remove-user)
      remove_user_action
      ;;
    logs)
      logs_action
      ;;
    *)
      usage_error "Unknown action: ${ACTION}"
      ;;
  esac
}

main "$@"
