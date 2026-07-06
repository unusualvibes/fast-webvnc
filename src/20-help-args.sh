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
