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
