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

  if [[ -z "$HOSTNAME_VALUE" || "$HOSTNAME_VALUE" == *"/"* || "$HOSTNAME_VALUE" == *":"* ]]; then
    die "$EXIT_USAGE" "--hostname must be a hostname or IPv4 address, not a URL."
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
    fi
    return
  fi

  [[ -f "$PROVIDED_CERT_FILE" ]] || die "$EXIT_PRECHECK" "Provided certificate file not found: ${PROVIDED_CERT_FILE}"
  [[ -f "$PROVIDED_KEY_FILE" ]] || die "$EXIT_PRECHECK" "Provided private key file not found: ${PROVIDED_KEY_FILE}"
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
