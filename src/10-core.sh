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
    rollback_backup_dir "$BACKUP_DIR_CURRENT"
    cleanup_empty_managed_dirs
    set -e
  fi

  exit "$status"
}

trap 'err_trap "$LINENO" "$?"' ERR

