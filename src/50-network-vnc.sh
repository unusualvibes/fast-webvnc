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

  output="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null || true)"
  [[ "$output" == loaded ]]
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
  local wayland=0

  find_wayland_session && wayland=1

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if ! systemd_unit_exists "$unit"; then
      continue
    fi

    # RealVNC can answer RFB on Wayland while displaying only an error page.
    if (( wayland )) && [[ "$unit" != wayvnc.service ]]; then
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

# Inspect the configured port, not unrelated VNC processes on other displays.
vnc_backend_is_x11() {
  local lines
  lines="$(list_listener_lines_on_port "$VNC_PORT")"
  grep -Eq '"(vncserver-x11[^" ]*|x11vnc)"' <<<"$lines"
}

migrate_x11_backend_to_wayland() {
  local realvnc_active=0
  local managed_active=0
  local previous_backend=""

  warn "An X11 VNC server is answering on ${VNC_HOST}:${VNC_PORT}, but the desktop uses Wayland; switching to WayVNC."
  if (( DRY_RUN )); then
    info "DRY-RUN: stop the X11 backend and configure WayVNC for the Wayland desktop"
    return 0
  fi

  # Stop services rather than killing whichever PID happens to own the port.
  if systemctl is-active --quiet vncserver-x11-serviced.service; then
    realvnc_active=1
    systemctl stop vncserver-x11-serviced.service || return 1
  fi
  if managed_file_has_marker "$VNC_BACKEND_SERVICE_FILE" &&
    systemctl is-active --quiet "$VNC_BACKEND_SERVICE_NAME"; then
    managed_active=1
    previous_backend="$(mktemp)"
    cp -p "$VNC_BACKEND_SERVICE_FILE" "$previous_backend"
    systemctl stop "$VNC_BACKEND_SERVICE_NAME" || return 1
  fi

  # An administrator-started X11 server must be stopped by its owner.
  if vnc_backend_is_x11; then
    warn "The X11 listener is still running. Stop it before re-running installation."
  elif { systemd_unit_exists wayvnc.service && start_hardened_raspberry_pi_vnc; } ||
    try_start_wayland_backend; then
    if (( realvnc_active )); then
      systemctl disable vncserver-x11-serviced.service || return 1
    fi
    if (( managed_active )) && systemd_unit_exists wayvnc.service; then
      systemctl disable "$VNC_BACKEND_SERVICE_NAME" || return 1
    fi
    [[ -z "$previous_backend" ]] || rm -f "$previous_backend"
    require_vnc_loopback_only
    return 0
  fi

  # Preserve the previous backend when WayVNC cannot start.
  if (( realvnc_active )); then
    systemctl start vncserver-x11-serviced.service || true
  fi
  if (( managed_active )); then
    systemctl stop "$VNC_BACKEND_SERVICE_NAME" || true
    cp -p "$previous_backend" "$VNC_BACKEND_SERVICE_FILE"
    rm -f "$previous_backend"
    systemctl daemon-reload
    systemctl start "$VNC_BACKEND_SERVICE_NAME" || true
  fi
  return 1
}

# The main VNC backend gate for install: confirm a VNC server answers on the
# configured host/port and (for localhost) that it only listens on loopback.
# If nothing answers and auto-setup is allowed, try to enable and harden the
# Raspberry Pi VNC service before giving up with remediation advice.
ensure_vnc_backend() {
  info "Checking VNC backend at ${VNC_HOST}:${VNC_PORT}"

  if is_local_host "$VNC_HOST" && find_wayland_session && vnc_backend_is_x11; then
    if (( ! AUTO_VNC_BACKEND )); then
      die "$EXIT_PRECHECK" "An X11 VNC backend is serving ${VNC_HOST}:${VNC_PORT} while the desktop uses Wayland. Enable WayVNC or re-run with --auto-vnc."
    fi
    if migrate_x11_backend_to_wayland; then
      mark_managed_vnc_backend_if_present
      return
    fi
    die "$EXIT_PRECHECK" "Could not replace the X11 VNC backend with WayVNC. Check the WayVNC service logs and ensure the labwc desktop is logged in."
  fi

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

  if find_wayland_session; then
    if { systemd_unit_exists wayvnc.service && start_hardened_raspberry_pi_vnc; } || try_start_wayland_backend; then
      require_vnc_loopback_only
      mark_managed_vnc_backend_if_present
      return
    fi
    die "$EXIT_PRECHECK" "WayVNC could not start for the Wayland desktop. Check journalctl -u wayvnc.service -u ${VNC_BACKEND_SERVICE_NAME}. RealVNC cannot share this desktop."
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
