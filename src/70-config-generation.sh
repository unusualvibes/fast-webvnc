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
curl -sf -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
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
record_id="$(curl -sf \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=_acme-challenge.${CERTBOT_DOMAIN}&content=${CERTBOT_VALIDATION}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"]) if r else ""')"
[[ -n "$record_id" ]] && curl -sf -X DELETE \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" >/dev/null || true
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
