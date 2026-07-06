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
