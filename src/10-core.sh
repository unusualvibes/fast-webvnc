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

run() {
  if (( DRY_RUN )); then
    info "DRY-RUN: $*"
    return 0
  fi

  debug "Running: $*"
  "$@"
}

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
    rollback_backup_dir "$BACKUP_DIR_CURRENT"
    cleanup_empty_managed_dirs
    set -e
  fi

  exit "$status"
}

trap 'err_trap "$LINENO" "$?"' ERR

