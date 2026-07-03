# shellcheck shell=bash
# vm.sh — swappiness fallback (RF-03, spec §7). Only runs when GameMode absent.

vm::apply() {
  if gamemode::is_available; then
    log::info "vm: GameMode present — skipping manual swappiness change"
    return 0
  fi
  local current
  current="$(cat /proc/sys/vm/swappiness 2>/dev/null)" || current="60"
  state::save_once vm-swappiness "$current"
  log::info "vm: setting vm.swappiness=10 (was $current)"
  if ! printf '10\n' | sudo::run tee /proc/sys/vm/swappiness >/dev/null; then
    log::error "vm: failed to set swappiness"
  fi
  return 0
}

vm::revert() {
  if ! state::has vm-swappiness; then
    log::info "vm: no saved swappiness — nothing to revert"
    return 0
  fi
  local value
  value="$(state::load vm-swappiness)"
  [[ "$value" =~ ^[0-9]+$ ]] || value="60"
  log::info "vm: restoring vm.swappiness=$value"
  if printf '%s\n' "$value" | sudo::run tee /proc/sys/vm/swappiness >/dev/null; then
    state::clear vm-swappiness
  else
    log::error "vm: failed to restore swappiness"
  fi
  return 0
}

registry::register vm vm::apply vm::revert
