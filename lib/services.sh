# shellcheck shell=bash
# services.sh — stop/restore of the fixed non-essential service set (Appendix A).
# Every stop is guarded by the denylist and verified via 'systemctl is-active'
# before being reported as success (RNF-02, RF-01).

readonly REAP_SERVICES=(
  ollama                # disputes GPU VRAM — biggest single win (B7)
  postgresql@18-main    # background I/O (B7)
  snapd
  unattended-upgrades   # could fire apt mid-game
  packagekit
  gnome-remote-desktop
  ModemManager
  avahi-daemon
  colord
  cups
  fwupd
  whoopsie
  atd
)

readonly REAP_ACTIVE_SERVICES_KEY="was-active-services"

svc::_has_systemctl() { command -v systemctl >/dev/null 2>&1; }

svc::is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# RF-01 + RNF-03: record the originally-active services once, then stop them.
# On a second 'gaming' run the record already exists and is not rebuilt, so the
# real original set is preserved even though the services are now inactive.
svc::stop_configured() {
  if ! svc::_has_systemctl; then
    log::warn "systemctl unavailable — skipping service management"
    return 0
  fi

  local active_file first_run=1 svc
  active_file="$(state::path "$REAP_ACTIVE_SERVICES_KEY")"
  state::has "$REAP_ACTIVE_SERVICES_KEY" && first_run=0

  if ((first_run)); then
    state::init
    : >"$active_file"
  fi

  for svc in "${REAP_SERVICES[@]}"; do
    if svc::is_protected "$svc"; then
      log::warn "'$svc' is in the denylist — never stopped"
      continue
    fi
    if ! svc::is_active "$svc"; then
      log::info "'$svc' not active — nothing to stop"
      continue
    fi
    ((first_run)) && printf '%s\n' "$svc" >>"$active_file"

    log::info "stopping service '$svc'"
    if ! sudo::run systemctl stop "$svc"; then
      log::error "'$svc' stop command failed"
      continue
    fi
    if svc::is_active "$svc"; then
      log::error "'$svc' still active after stop — verification failed"
    else
      log::info "'$svc' stopped and verified"
    fi
  done
  return 0
}

svc::_start_verified() {
  local svc="$1"
  # Defensive: never start something now covered by the denylist.
  if svc::is_protected "$svc"; then
    log::warn "'$svc' is protected — refusing to start"
    return 0
  fi
  log::info "starting service '$svc'"
  if ! sudo::run systemctl start "$svc"; then
    log::error "'$svc' start command failed"
    return 0
  fi
  if svc::is_active "$svc"; then
    log::info "'$svc' started and verified"
  else
    log::warn "'$svc' not active after start"
  fi
  return 0
}

# RF-04/RF-05 + bug B3: restore ONLY the services recorded as active before
# 'gaming'. Returns non-zero (no side effects) when no record exists, so the
# caller can no-op instead of starting services blindly.
svc::restore() {
  local active_file svc
  active_file="$(state::path "$REAP_ACTIVE_SERVICES_KEY")"
  [[ -f "$active_file" ]] || return 1

  if ! svc::_has_systemctl; then
    log::warn "systemctl unavailable — cannot restore services"
    return 0
  fi

  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    svc::_start_verified "$svc"
  done <"$active_file"

  state::clear "$REAP_ACTIVE_SERVICES_KEY"
  return 0
}
