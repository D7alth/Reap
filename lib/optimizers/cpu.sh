# shellcheck shell=bash
# cpu.sh — manual CPU fallback, PPD-aware (RF-03, bug B5).
# Only runs when GameMode is absent. Never writes scaling_governor blindly:
# if power-profiles-daemon is present it drives the profile through
# powerprofilesctl (so PPD won't override it); otherwise it falls back to sysfs.
# Guarded by thermal::guard.

cpu::_ppd_available() { command -v powerprofilesctl >/dev/null 2>&1; }

cpu::apply() {
  if gamemode::is_available; then
    log::info "cpu: GameMode present — skipping manual CPU tuning"
    return 0
  fi
  if ! thermal::guard; then
    log::warn "cpu: thermal guard failed — leaving CPU settings unchanged"
    return 0
  fi
  if cpu::_ppd_available; then
    cpu::_apply_ppd
  else
    cpu::_apply_sysfs
  fi
  return 0
}

cpu::_apply_ppd() {
  local current
  current="$(powerprofilesctl get 2>/dev/null)" || current=""
  [[ -n "$current" ]] && state::save_once ppd-profile "$current"
  log::info "cpu: setting power profile to 'performance' via powerprofilesctl"
  if ! powerprofilesctl set performance; then
    log::error "cpu: failed to set 'performance' profile"
  fi
}

cpu::_apply_sysfs() {
  local governor="" node
  for node in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -r "$node" ]] || continue
    governor="$(cat "$node")"
    break
  done
  [[ -n "$governor" ]] && state::save_once cpu-governor "$governor"
  log::info "cpu: setting governor to 'performance' via sysfs"
  for node in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -e "$node" ]] || continue
    printf 'performance\n' | sudo::run tee "$node" >/dev/null || log::error "cpu: failed to write governor at $node"
  done
}

cpu::revert() {
  if state::has ppd-profile; then
    local profile
    profile="$(state::load ppd-profile)"
    log::info "cpu: restoring power profile '$profile'"
    if powerprofilesctl set "$profile"; then
      state::clear ppd-profile
    else
      log::error "cpu: failed to restore profile '$profile'"
    fi
    return 0
  fi
  if state::has cpu-governor; then
    local governor node
    governor="$(state::load cpu-governor)"
    log::info "cpu: restoring governor '$governor'"
    for node in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
      [[ -e "$node" ]] || continue
      printf '%s\n' "$governor" | sudo::run tee "$node" >/dev/null || log::error "cpu: failed to restore governor at $node"
    done
    state::clear cpu-governor
    return 0
  fi
  log::info "cpu: no saved CPU state — nothing to revert"
  return 0
}

registry::register cpu cpu::apply cpu::revert
