# shellcheck shell=bash
# status.sh — `reap status` (spec §9 v1.1). Read-only: no sudo, no lock, so it
# works anytime, including mid-session. Reports whether gaming mode is active,
# what reap changed (from saved state), the live kernel state, and the last
# executions from the journal.

status::_current_governor() {
  local node
  for node in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -r "$node" ]] || continue
    cat "$node"
    return 0
  done
  printf 'unknown'
}

status::_current_ppd() {
  command -v powerprofilesctl >/dev/null 2>&1 || {
    printf 'n/a'
    return 0
  }
  powerprofilesctl get 2>/dev/null || printf 'unknown'
}

reap::status() {
  local active="no" svc
  if state::has "$REAP_ACTIVE_SERVICES_KEY" || reap::_has_optimizer_state; then
    active="yes"
  fi

  printf 'reap — status\n\n'
  printf 'gaming mode active: %s\n\n' "$active"

  printf 'changed by reap (restored on exit):\n'
  if state::has "$REAP_ACTIVE_SERVICES_KEY"; then
    printf '  services stopped:\n'
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && printf '    - %s\n' "$svc"
    done <"$(state::path "$REAP_ACTIVE_SERVICES_KEY")"
  else
    printf '  services: none recorded\n'
  fi
  state::has vm-swappiness && printf '  vm.swappiness (original): %s\n' "$(state::load vm-swappiness)"
  state::has cpu-governor && printf '  cpu governor (original): %s\n' "$(state::load cpu-governor)"
  state::has ppd-profile && printf '  power profile (original): %s\n' "$(state::load ppd-profile)"
  printf '\n'

  printf 'current kernel state:\n'
  printf '  vm.swappiness: %s\n' "$(cat /proc/sys/vm/swappiness 2>/dev/null || printf unknown)"
  printf '  cpu governor:  %s\n' "$(status::_current_governor)"
  printf '  power profile: %s\n' "$(status::_current_ppd)"
  printf '\n'

  printf 'recent executions (last %s):\n' "$REAP_LOG_MAX_SESSIONS"
  journal::summary "$REAP_LOG_MAX_SESSIONS"
  return 0
}
