state_write_line() {
  local key="$1"
  local value="$2"
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
