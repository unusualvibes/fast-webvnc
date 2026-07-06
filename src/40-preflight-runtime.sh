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
